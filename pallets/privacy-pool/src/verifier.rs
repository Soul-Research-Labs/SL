//! ZK proof verification for the Privacy Pool pallet.
//!
//! In production, this module will directly call lumora-verifier's
//! `verify_transfer()` and `verify_withdraw()` functions.
//!
//! For now, it provides a placeholder that accepts well-formed proofs
//! on testnets. The actual Halo2 verification will be integrated once
//! lumora-verifier gains `no_std` support (feature-gated).
//!
//! ## Integration Plan
//!
//! 1. Add `lumora-verifier = { path = "../../lumora-verifier", default-features = false }`
//! 2. Enable `no_std` feature in lumora-verifier
//! 3. Replace `verify_transfer_placeholder` with `lumora_verifier::verify_transfer()`
//! 4. Benchmark the actual verification weight

use sp_std::vec::Vec;
use crate::types::{TransferPublicInputs, WithdrawPublicInputs};

/// Minimum valid proof size (bytes)
const MIN_PROOF_SIZE: usize = 256;

/// Maximum valid proof size (bytes)
const MAX_PROOF_SIZE: usize = 4096;

/// Verify a transfer ZK proof.
///
/// # Arguments
/// * `proof` - The serialized proof bytes
/// * `public_inputs` - The Transfer circuit public inputs
///
/// # Returns
/// `true` if the proof is valid
pub fn verify_transfer(proof: &[u8], public_inputs: &TransferPublicInputs) -> bool {
    // Structural validation
    if proof.len() < MIN_PROOF_SIZE || proof.len() > MAX_PROOF_SIZE {
        return false;
    }

    // Ensure public inputs are non-trivial
    if public_inputs.merkle_root == sp_core::H256::zero() {
        return false;
    }

    // Check nullifiers are distinct
    if public_inputs.nullifiers[0] == public_inputs.nullifiers[1] {
        return false;
    }

    // TODO: Replace with actual Halo2 verification from lumora-verifier
    // when no_std support is available:
    //
    // use lumora_verifier::verify_transfer_proof;
    // let circuit_inputs = build_transfer_circuit_inputs(public_inputs);
    // verify_transfer_proof(proof, &circuit_inputs, &TRANSFER_VK)
    //
    // Weight benchmark: ~5-10ms on standard hardware for k=13 circuit

    // PLACEHOLDER: Accept structurally valid proofs
    // MUST BE REPLACED before mainnet deployment
    true
}

/// Verify a withdrawal ZK proof.
///
/// # Arguments
/// * `proof` - The serialized proof bytes
/// * `public_inputs` - The Withdraw circuit public inputs
///
/// # Returns
/// `true` if the proof is valid
pub fn verify_withdraw(proof: &[u8], public_inputs: &WithdrawPublicInputs) -> bool {
    if proof.len() < MIN_PROOF_SIZE || proof.len() > MAX_PROOF_SIZE {
        return false;
    }

    if public_inputs.merkle_root == sp_core::H256::zero() {
        return false;
    }

    if public_inputs.nullifiers[0] == public_inputs.nullifiers[1] {
        return false;
    }

    if public_inputs.exit_value == 0 {
        return false;
    }

    // TODO: Replace with actual Halo2 verification from lumora-verifier
    // use lumora_verifier::verify_withdraw_proof;
    // let circuit_inputs = build_withdraw_circuit_inputs(public_inputs);
    // verify_withdraw_proof(proof, &circuit_inputs, &WITHDRAW_VK)

    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use sp_core::H256;

    #[test]
    fn test_reject_empty_proof() {
        let inputs = TransferPublicInputs {
            merkle_root: H256::from([1u8; 32]),
            nullifiers: [H256::from([2u8; 32]), H256::from([3u8; 32])],
            output_commitments: [H256::from([4u8; 32]), H256::from([5u8; 32])],
            domain_chain_id: 1000,
            domain_app_id: 1,
        };
        assert!(!verify_transfer(&[], &inputs));
    }

    #[test]
    fn test_reject_zero_root() {
        let inputs = TransferPublicInputs {
            merkle_root: H256::zero(),
            nullifiers: [H256::from([2u8; 32]), H256::from([3u8; 32])],
            output_commitments: [H256::from([4u8; 32]), H256::from([5u8; 32])],
            domain_chain_id: 1000,
            domain_app_id: 1,
        };
        let proof = vec![0u8; 512];
        assert!(!verify_transfer(&proof, &inputs));
    }

    #[test]
    fn test_reject_duplicate_nullifiers() {
        let nul = H256::from([2u8; 32]);
        let inputs = TransferPublicInputs {
            merkle_root: H256::from([1u8; 32]),
            nullifiers: [nul, nul],
            output_commitments: [H256::from([4u8; 32]), H256::from([5u8; 32])],
            domain_chain_id: 1000,
            domain_app_id: 1,
        };
        let proof = vec![0u8; 512];
        assert!(!verify_transfer(&proof, &inputs));
    }

    #[test]
    fn test_accept_valid_structure() {
        let inputs = TransferPublicInputs {
            merkle_root: H256::from([1u8; 32]),
            nullifiers: [H256::from([2u8; 32]), H256::from([3u8; 32])],
            output_commitments: [H256::from([4u8; 32]), H256::from([5u8; 32])],
            domain_chain_id: 1000,
            domain_app_id: 1,
        };
        let proof = vec![0u8; 512];
        // Placeholder accepts structurally valid proofs
        assert!(verify_transfer(&proof, &inputs));
    }
}
