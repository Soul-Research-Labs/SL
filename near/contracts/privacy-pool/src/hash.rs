//! Poseidon hash placeholder for the NEAR Privacy Pool.
//!
//! Uses NEAR's native keccak256 with a "Poseidon" domain tag.
//!
//! ## Production upgrade path
//!
//! Replace with `light-poseidon` crate compiled to WASM for exact BN254
//! field-arithmetic alignment with `PoseidonHasher.sol` and the Noir
//! circuit constraints.

use near_sdk::env;

pub const ZERO_HASH: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

/// Domain-tagged keccak256 hash standing in for BN254 Poseidon.
pub fn poseidon_hash_hex(left: &str, right: &str) -> String {
    let mut data = Vec::with_capacity(8 + left.len() + right.len());
    data.extend_from_slice(b"Poseidon");
    data.extend_from_slice(left.as_bytes());
    data.extend_from_slice(right.as_bytes());
    let hash = env::keccak256(&data);
    hex::encode(hash)
}

/// Compute the zero-hash at a given Merkle tree level.
pub fn zero_hash(level: u32) -> String {
    let mut z = ZERO_HASH.to_string();
    for _ in 0..level {
        z = poseidon_hash_hex(&z, &z);
    }
    z
}

/// Compute linearised nullifier root from an ordered list of nullifier hex strings.
pub fn compute_nullifier_root(nullifiers: &[String]) -> String {
    if nullifiers.is_empty() {
        return ZERO_HASH.to_string();
    }
    let mut current = nullifiers[0].clone();
    for nul in &nullifiers[1..] {
        current = poseidon_hash_hex(&current, nul);
    }
    current
}
