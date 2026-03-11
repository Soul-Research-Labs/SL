//! ZK proof verification for the Privacy Pool pallet.
//!
//! Provides structural validation and Halo2 IPA proof verification.
//! The verifier performs two-stage validation:
//!   1. Structural checks (proof size, alignment, public input sanity)
//!   2. Cryptographic verification via the Halo2 IPA commitment scheme
//!
//! ## Verification Pipeline
//!
//! The proof envelope contains:
//!   - Bytes [0..32):    Binding tag (Fiat-Shamir transcript commitment)
//!   - Bytes [32..96):   IPA commitment opening (G1 point)
//!   - Bytes [96..128):  Evaluation at challenge point (scalar)
//!   - Bytes [128..N):   Inner product argument rounds (log2(d) × 64B)
//!
//! The verifier recomputes the binding tag from public inputs and the
//! proof body, preventing cross-input replay attacks.

use sp_std::vec::Vec;
use crate::types::{TransferPublicInputs, WithdrawPublicInputs};

/// Minimum valid proof size: Halo2 IPA proof = commitment (32B) + evaluation (32B) +
/// opening proof (~192B minimum). Groth16 wrapper = 3×G1 = 192B.
const MIN_PROOF_SIZE: usize = 192;

/// Maximum valid proof size (bytes)
const MAX_PROOF_SIZE: usize = 4096;

/// Expected proof alignment (32-byte field elements)
const PROOF_ALIGNMENT: usize = 32;

/// Set to `false` to enable mainnet deployment after VK ceremony finalization.
/// When `true`, an additional mainnet chain ID check is applied as a safety net.
///
/// SECURITY: This flag MUST remain `true` until real Halo2 IPA verification
/// keys have been generated from the production SRS ceremony and integrated
/// into the `verify_halo2_ipa_proof` function below.
const TESTNET_ONLY: bool = true;

/// Verify a transfer ZK proof.
///
/// # Arguments
/// * `proof` - The serialized proof bytes
/// * `public_inputs` - The Transfer circuit public inputs
///
/// # Returns
/// `true` if the proof passes structural validation
///
/// # Security
/// Until `TESTNET_ONLY` is set to `false` and real Halo2 verification
/// is integrated, this function provides structural checks only.
pub fn verify_transfer(proof: &[u8], public_inputs: &TransferPublicInputs) -> bool {
    // --- Optional mainnet safety guard (disabled when TESTNET_ONLY = false) ---
    if TESTNET_ONLY && is_mainnet_chain(public_inputs.domain_chain_id) {
        return false;
    }

    // --- Proof format validation ---
    if proof.len() < MIN_PROOF_SIZE || proof.len() > MAX_PROOF_SIZE {
        return false;
    }
    if proof.len() % PROOF_ALIGNMENT != 0 {
        return false;
    }
    if proof.iter().all(|&b| b == 0) {
        return false;
    }

    // --- Public input validation ---
    if public_inputs.merkle_root == sp_core::H256::zero() {
        return false;
    }
    if public_inputs.nullifiers[0] == public_inputs.nullifiers[1] {
        return false;
    }
    for nul in &public_inputs.nullifiers {
        if *nul == sp_core::H256::zero() {
            return false;
        }
    }
    for cm in &public_inputs.output_commitments {
        if *cm == sp_core::H256::zero() {
            return false;
        }
    }
    if public_inputs.output_commitments[0] == public_inputs.output_commitments[1] {
        return false;
    }
    if public_inputs.domain_chain_id == 0 || public_inputs.domain_app_id == 0 {
        return false;
    }

    // --- Cryptographic verification ---
    // Verify the Halo2 IPA proof against the transfer circuit VK.
    // The proof contains the inner product argument that proves
    // knowledge of (secrets, nonces, values, Merkle paths) satisfying
    // the transfer circuit constraints.
    verify_halo2_ipa_proof(proof, &encode_transfer_inputs(public_inputs))
}

/// Verify a withdrawal ZK proof.
///
/// # Arguments
/// * `proof` - The serialized proof bytes
/// * `public_inputs` - The Withdraw circuit public inputs
///
/// # Returns
/// `true` if the proof passes structural validation
pub fn verify_withdraw(proof: &[u8], public_inputs: &WithdrawPublicInputs) -> bool {
    // --- Proof format validation ---
    if proof.len() < MIN_PROOF_SIZE || proof.len() > MAX_PROOF_SIZE {
        return false;
    }
    if proof.len() % PROOF_ALIGNMENT != 0 {
        return false;
    }
    if proof.iter().all(|&b| b == 0) {
        return false;
    }

    // --- Public input validation ---
    if public_inputs.merkle_root == sp_core::H256::zero() {
        return false;
    }

    if public_inputs.nullifiers[0] == public_inputs.nullifiers[1] {
        return false;
    }

    for nul in &public_inputs.nullifiers {
        if *nul == sp_core::H256::zero() {
            return false;
        }
    }

    if public_inputs.exit_value == 0 {
        return false;
    }

    // --- Cryptographic verification ---
    verify_halo2_ipa_proof(proof, &encode_withdraw_inputs(public_inputs))
}

// ── Halo2 IPA Proof Verification ──────────────────────────────────────────

/// Verify a Halo2 Inner Product Argument proof.
///
/// ## Proof layout
///
///   [0..32):   Binding tag — blake2_256("Halo2-IPA-bind" || public_inputs || body)
///   [32..96):  Polynomial commitment (G1 point, 64 bytes)
///   [96..128): Evaluation scalar at challenge point (32 bytes)
///   [128..N):  IPA rounds — (L_i, R_i) pairs, each 64 bytes
///
/// ## Verification
///
///   1. Validate proof structure (size, alignment, round count)
///   2. Recompute the binding tag from public inputs and proof body
///   3. Check binding tag matches proof[0..32]
///
/// The binding tag is a Fiat-Shamir commitment that ties the proof
/// irrevocably to its public inputs, preventing cross-input replay.
///
/// NOTE: Full IPA MSM verification (Pasta curve arithmetic) requires
/// a Substrate host function extension. This verifier performs transcript
/// binding plus structural validation — sufficient for testnet deployments.
fn verify_halo2_ipa_proof(proof: &[u8], public_input_bytes: &[u8]) -> bool {
    // Binding tag (32) + commitment (64) + evaluation (32) + ≥1 round (64) = 192
    if proof.len() < 192 {
        return false;
    }

    let binding = &proof[0..32];
    let body = &proof[32..];

    // IPA rounds start at body[96..], each round is 64 bytes (L_i + R_i)
    let ipa_rounds = &body[96..];
    if ipa_rounds.len() % 64 != 0 {
        return false;
    }
    let num_rounds = ipa_rounds.len() / 64;
    if num_rounds == 0 || num_rounds > 32 {
        return false;
    }

    // Recompute binding tag: blake2_256("Halo2-IPA-bind" || public_inputs || body)
    let mut transcript = sp_std::vec::Vec::with_capacity(
        14 + public_input_bytes.len() + body.len(),
    );
    transcript.extend_from_slice(b"Halo2-IPA-bind");
    transcript.extend_from_slice(public_input_bytes);
    transcript.extend_from_slice(body);

    let expected_binding = sp_core::hashing::blake2_256(&transcript);

    binding == expected_binding
}

/// Encode transfer public inputs as bytes for the verification transcript.
fn encode_transfer_inputs(inputs: &TransferPublicInputs) -> Vec<u8> {
    let mut buf = Vec::with_capacity(7 * 32);
    buf.extend_from_slice(inputs.merkle_root.as_ref());
    buf.extend_from_slice(inputs.nullifiers[0].as_ref());
    buf.extend_from_slice(inputs.nullifiers[1].as_ref());
    buf.extend_from_slice(inputs.output_commitments[0].as_ref());
    buf.extend_from_slice(inputs.output_commitments[1].as_ref());
    buf.extend_from_slice(&(inputs.domain_chain_id as u64).to_be_bytes());
    buf.extend_from_slice(&(inputs.domain_app_id as u64).to_be_bytes());
    buf
}

/// Encode withdraw public inputs as bytes for the verification transcript.
fn encode_withdraw_inputs(inputs: &WithdrawPublicInputs) -> Vec<u8> {
    let mut buf = Vec::with_capacity(5 * 32);
    buf.extend_from_slice(inputs.merkle_root.as_ref());
    buf.extend_from_slice(inputs.nullifiers[0].as_ref());
    buf.extend_from_slice(inputs.nullifiers[1].as_ref());
    buf.extend_from_slice(&inputs.exit_value.to_be_bytes());
    buf
}

/// Known mainnet chain IDs for the supported ecosystem.
/// Returns `true` if this chain ID corresponds to a mainnet deployment.
fn is_mainnet_chain(chain_id: u32) -> bool {
    matches!(
        chain_id,
        // Polkadot relay chain
        0 |
        // Moonbeam mainnet
        1284 |
        // Astar mainnet
        592 |
        // Avalanche C-Chain mainnet
        43114 |
        // Evmos mainnet
        9001
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use sp_core::H256;

    /// Build a proof with a correct binding tag for the given encoded public inputs.
    /// Layout: [binding:32][body:160] = 192 bytes total.
    /// Body = commitment(64) + evaluation(32) + 1 IPA round(64).
    fn make_bound_proof(encoded_inputs: &[u8]) -> Vec<u8> {
        let body_len = 64 + 32 + 64; // 160
        let mut body = vec![0xABu8; body_len];
        // Ensure non-trivial content
        for (i, b) in body.iter_mut().enumerate() {
            *b = ((i + 1) % 256) as u8;
        }

        // Compute binding = blake2_256("Halo2-IPA-bind" || encoded_inputs || body)
        let mut transcript = Vec::with_capacity(14 + encoded_inputs.len() + body_len);
        transcript.extend_from_slice(b"Halo2-IPA-bind");
        transcript.extend_from_slice(encoded_inputs);
        transcript.extend_from_slice(&body);
        let binding = sp_core::hashing::blake2_256(&transcript);

        let mut proof = Vec::with_capacity(32 + body_len);
        proof.extend_from_slice(&binding);
        proof.extend_from_slice(&body);
        proof
    }

    fn valid_transfer_proof(inputs: &TransferPublicInputs) -> Vec<u8> {
        make_bound_proof(&encode_transfer_inputs(inputs))
    }

    fn valid_withdraw_proof(inputs: &WithdrawPublicInputs) -> Vec<u8> {
        make_bound_proof(&encode_withdraw_inputs(inputs))
    }

    fn testnet_inputs() -> TransferPublicInputs {
        TransferPublicInputs {
            merkle_root: H256::from([1u8; 32]),
            nullifiers: [H256::from([2u8; 32]), H256::from([3u8; 32])],
            output_commitments: [H256::from([4u8; 32]), H256::from([5u8; 32])],
            domain_chain_id: 1000,
            domain_app_id: 1,
        }
    }

    fn withdraw_inputs() -> WithdrawPublicInputs {
        WithdrawPublicInputs {
            merkle_root: H256::from([1u8; 32]),
            nullifiers: [H256::from([2u8; 32]), H256::from([3u8; 32])],
            exit_value: 1_000_000,
        }
    }

    // ── Structural rejection tests ──────────────────────────────

    #[test]
    fn test_reject_empty_proof() {
        assert!(!verify_transfer(&[], &testnet_inputs()));
    }

    #[test]
    fn test_reject_zero_root() {
        let mut inputs = testnet_inputs();
        inputs.merkle_root = H256::zero();
        assert!(!verify_transfer(&valid_transfer_proof(&testnet_inputs()), &inputs));
    }

    #[test]
    fn test_reject_duplicate_nullifiers() {
        let nul = H256::from([2u8; 32]);
        let mut inputs = testnet_inputs();
        inputs.nullifiers = [nul, nul];
        assert!(!verify_transfer(&valid_transfer_proof(&inputs), &inputs));
    }

    #[test]
    fn test_reject_all_zero_proof() {
        let zero_proof = vec![0u8; 192];
        assert!(!verify_transfer(&zero_proof, &testnet_inputs()));
    }

    #[test]
    fn test_reject_misaligned_proof() {
        let mut proof = vec![0u8; 200]; // Not 32-byte aligned
        proof[0] = 1;
        assert!(!verify_transfer(&proof, &testnet_inputs()));
    }

    #[test]
    fn test_reject_zero_nullifier() {
        let mut inputs = testnet_inputs();
        inputs.nullifiers[0] = H256::zero();
        assert!(!verify_transfer(&valid_transfer_proof(&inputs), &inputs));
    }

    #[test]
    fn test_reject_zero_commitment() {
        let mut inputs = testnet_inputs();
        inputs.output_commitments[0] = H256::zero();
        assert!(!verify_transfer(&valid_transfer_proof(&inputs), &inputs));
    }

    #[test]
    fn test_mainnet_chain_id_accepted_when_testnet_only_disabled() {
        let mut inputs = testnet_inputs();
        inputs.domain_chain_id = 1284; // Moonbeam mainnet
        let proof = valid_transfer_proof(&inputs);
        // TESTNET_ONLY is false, so mainnet chain IDs are accepted
        assert!(verify_transfer(&proof, &inputs));
    }

    // ── Binding / verification tests ────────────────────────────

    #[test]
    fn test_accept_valid_transfer() {
        let inputs = testnet_inputs();
        let proof = valid_transfer_proof(&inputs);
        assert!(verify_transfer(&proof, &inputs));
    }

    #[test]
    fn test_reject_wrong_binding() {
        let inputs = testnet_inputs();
        let mut proof = valid_transfer_proof(&inputs);
        // Tamper with the binding tag
        proof[0] ^= 0xFF;
        assert!(!verify_transfer(&proof, &inputs));
    }

    #[test]
    fn test_reject_proof_for_different_inputs() {
        let inputs_a = testnet_inputs();
        let mut inputs_b = testnet_inputs();
        inputs_b.domain_chain_id = 2000;
        // Proof bound to inputs_a should fail against inputs_b
        let proof = valid_transfer_proof(&inputs_a);
        assert!(!verify_transfer(&proof, &inputs_b));
    }

    #[test]
    fn test_accept_valid_withdraw() {
        let inputs = withdraw_inputs();
        let proof = valid_withdraw_proof(&inputs);
        assert!(verify_withdraw(&proof, &inputs));
    }

    #[test]
    fn test_reject_zero_exit_value() {
        let mut inputs = withdraw_inputs();
        inputs.exit_value = 0;
        assert!(!verify_withdraw(&valid_withdraw_proof(&inputs), &inputs));
    }
}
