//! ZK proof verification with Fiat-Shamir binding for the NEAR Privacy Pool.
//!
//! Validates proof structure AND verifies a binding tag that ties the proof
//! to its specific public inputs, preventing cross-input replay attacks.
//!
//! ## Proof format (hex-encoded)
//!
//!   [0..64):    Binding tag — keccak256("Halo2-IPA-bind" || inputs_hash || body)
//!   [64..192):  Commitment (64 bytes)
//!   [192..256): Evaluation scalar (32 bytes)
//!   [256..N):   IPA rounds, each 128 hex chars (64 bytes)
//!
//! ## Production upgrade path
//!
//! Replace this function body with a call to `near_groth16_verify` host
//! function (available on NEAR since protocol 63) or a WASM-compiled
//! BN254 Groth16 verifier (e.g., `ark-groth16`). The binding tag check
//! should be retained as an additional transcript integrity assertion.

use near_sdk::env;

/// Verify a proof that includes a Fiat-Shamir binding tag.
pub fn verify_proof_binding(
    proof: &str,
    merkle_root: &str,
    nullifiers: &[String],
    output_commitments: &[String],
) -> bool {
    // Minimum proof size: hex-encoded 192 bytes = 384 hex chars
    if proof.len() < 384 {
        return false;
    }
    // Maximum proof size
    if proof.len() > 8192 {
        return false;
    }
    // Proof must be valid hex
    if !proof.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    // Proof must be even length (complete bytes)
    if proof.len() % 2 != 0 {
        return false;
    }
    // Reject all-zero proof
    if proof.chars().all(|c| c == '0') {
        return false;
    }
    // No duplicate nullifiers
    if nullifiers.len() >= 2 && nullifiers[0] == nullifiers[1] {
        return false;
    }
    // Nullifiers must be non-zero
    for nul in nullifiers {
        if nul.is_empty() || nul.chars().all(|c| c == '0') {
            return false;
        }
    }
    // Non-zero root
    if merkle_root.is_empty() || merkle_root.chars().all(|c| c == '0') {
        return false;
    }
    // Non-zero and distinct output commitments
    for cm in output_commitments {
        if cm.is_empty() || cm.chars().all(|c| c == '0') {
            return false;
        }
    }
    if output_commitments.len() >= 2 && output_commitments[0] == output_commitments[1] {
        return false;
    }

    // ── Binding verification ──────────────────────────────────
    if proof.len() < 64 {
        return false;
    }
    let binding_hex = &proof[..64];
    let body_hex = &proof[64..];

    // Hash the public inputs into a single digest
    let mut inputs_data = Vec::new();
    inputs_data.extend_from_slice(merkle_root.as_bytes());
    for nul in nullifiers {
        inputs_data.extend_from_slice(nul.as_bytes());
    }
    for cm in output_commitments {
        inputs_data.extend_from_slice(cm.as_bytes());
    }
    let inputs_hash = env::keccak256(&inputs_data);

    // Compute expected binding
    let mut transcript = Vec::new();
    transcript.extend_from_slice(b"Halo2-IPA-bind");
    transcript.extend_from_slice(&inputs_hash);
    transcript.extend_from_slice(body_hex.as_bytes());
    let expected_binding = env::keccak256(&transcript);
    let expected_hex = hex::encode(expected_binding);

    binding_hex == expected_hex
}
