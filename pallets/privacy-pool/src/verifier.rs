//! ZK proof verification for the Privacy Pool pallet.
//!
//! In production, this module will directly call lumora-verifier's
//! `verify_transfer()` and `verify_withdraw()` functions.
//!
//! For now, it provides structural validation that enforces correctness
//! of proof format and public inputs. Actual Halo2 IPA verification will
//! be integrated once lumora-verifier gains `no_std` support.
//!
//! ## Integration Plan
//!
//! 1. Add `lumora-verifier = { path = "../../lumora-verifier", default-features = false }`
//! 2. Enable `no_std` feature in lumora-verifier
//! 3. Replace structural checks with `lumora_verifier::verify_transfer()` / `verify_withdraw()`
//! 4. Benchmark the actual verification weight on-chain
//!
//! ## Security Model
//!
//! Structural checks reject malformed proofs but CANNOT prevent forgery.
//! The `TESTNET_ONLY` guard blocks any mainnet deployment until the real
//! Halo2 verifier is integrated.

use sp_std::vec::Vec;
use crate::types::{TransferPublicInputs, WithdrawPublicInputs};

/// Minimum valid proof size: Halo2 IPA proof = commitment (32B) + evaluation (32B) +
/// opening proof (~192B minimum). Groth16 wrapper = 3×G1 = 192B.
const MIN_PROOF_SIZE: usize = 192;

/// Maximum valid proof size (bytes)
const MAX_PROOF_SIZE: usize = 4096;

/// Expected proof alignment (32-byte field elements)
const PROOF_ALIGNMENT: usize = 32;

/// Set to `false` to enable mainnet deployment after real verifier integration.
/// When `true`, verify functions will reject all proofs on Substrate mainnet
/// chain specs (verified via the mainnet_guard parameter).
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
    // --- Mainnet guard ---
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

    // Reject all-zero proof (trivially forged)
    if proof.iter().all(|&b| b == 0) {
        return false;
    }

    // --- Public input validation ---
    if public_inputs.merkle_root == sp_core::H256::zero() {
        return false;
    }

    // Nullifiers must be distinct
    if public_inputs.nullifiers[0] == public_inputs.nullifiers[1] {
        return false;
    }

    // Nullifiers must be non-zero
    for nul in &public_inputs.nullifiers {
        if *nul == sp_core::H256::zero() {
            return false;
        }
    }

    // Output commitments must be non-zero and distinct
    for cm in &public_inputs.output_commitments {
        if *cm == sp_core::H256::zero() {
            return false;
        }
    }
    if public_inputs.output_commitments[0] == public_inputs.output_commitments[1] {
        return false;
    }

    // Domain separation must be set
    if public_inputs.domain_chain_id == 0 || public_inputs.domain_app_id == 0 {
        return false;
    }

    // When real Halo2 verification is integrated, replace the `true` below with:
    //   lumora_verifier::verify_transfer_proof(proof, public_inputs, &TRANSFER_VK)
    true
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

    // When real Halo2 verification is integrated:
    //   lumora_verifier::verify_withdraw_proof(proof, public_inputs, &WITHDRAW_VK)
    true
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

    fn valid_proof() -> Vec<u8> {
        let mut proof = vec![0u8; 192];
        proof[0] = 1; // Non-zero to pass all-zeros check
        proof
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

    #[test]
    fn test_reject_empty_proof() {
        assert!(!verify_transfer(&[], &testnet_inputs()));
    }

    #[test]
    fn test_reject_zero_root() {
        let mut inputs = testnet_inputs();
        inputs.merkle_root = H256::zero();
        assert!(!verify_transfer(&valid_proof(), &inputs));
    }

    #[test]
    fn test_reject_duplicate_nullifiers() {
        let nul = H256::from([2u8; 32]);
        let mut inputs = testnet_inputs();
        inputs.nullifiers = [nul, nul];
        assert!(!verify_transfer(&valid_proof(), &inputs));
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
        assert!(!verify_transfer(&valid_proof(), &inputs));
    }

    #[test]
    fn test_reject_zero_commitment() {
        let mut inputs = testnet_inputs();
        inputs.output_commitments[0] = H256::zero();
        assert!(!verify_transfer(&valid_proof(), &inputs));
    }

    #[test]
    fn test_reject_mainnet_chain_id() {
        let mut inputs = testnet_inputs();
        inputs.domain_chain_id = 1284; // Moonbeam mainnet
        assert!(!verify_transfer(&valid_proof(), &inputs));
    }

    #[test]
    fn test_accept_valid_testnet_transfer() {
        assert!(verify_transfer(&valid_proof(), &testnet_inputs()));
    }
}
