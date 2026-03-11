/// Cross-Chain Nullifier Inclusion Proof Circuit
///
/// Proves that a nullifier is included in a specific chain's epoch nullifier
/// Merkle tree, without revealing which leaf position it occupies.
/// Used by the UniversalNullifierRegistry for cross-chain double-spend prevention.
///
/// Public inputs:
///   - epoch_root: The nullifier tree root for a specific epoch on a chain
///   - nullifier: The nullifier being proven as spent
///
/// Private inputs:
///   - Merkle proof path and indices proving inclusion

use dep::std::hash::poseidon;

global TREE_DEPTH: u32 = 32;

fn compute_merkle_root(leaf: Field, path: [Field; 32], indices: [u1; 32]) -> Field {
    let mut current = leaf;
    for i in 0..TREE_DEPTH {
        let sibling = path[i];
        if indices[i] == 0 {
            current = poseidon::bn254::hash_2([current, sibling]);
        } else {
            current = poseidon::bn254::hash_2([sibling, current]);
        }
    }
    current
}

fn main(
    // Public inputs
    epoch_root: pub Field,
    nullifier: pub Field,

    // Private: Merkle inclusion proof
    path: [Field; 32],
    indices: [u1; 32],
) {
    // The nullifier itself is the leaf in the nullifier tree
    let computed_root = compute_merkle_root(nullifier, path, indices);
    assert(computed_root == epoch_root, "Nullifier not in epoch tree");
}

// ── Tests ──────────────────────────────────────────────────

#[test]
fn test_valid_nullifier_inclusion() {
    // Build a minimal Merkle tree with the nullifier as one leaf
    let nullifier = 42;
    let zero_sibling = 0;

    // Path: all zeros (left-child at every level)
    let mut path: [Field; 32] = [0; 32];
    let mut indices: [u1; 32] = [0; 32];

    // Compute the expected root by hashing up
    let mut current = nullifier;
    for i in 0..32 {
        current = poseidon::bn254::hash_2([current, zero_sibling]);
        path[i] = zero_sibling;
    }

    // Now compute root from scratch
    let epoch_root = compute_merkle_root(nullifier, path, indices);
    main(epoch_root, nullifier, path, indices);
}

#[test(should_fail_with = "Nullifier not in epoch tree")]
fn test_wrong_nullifier_fails() {
    let real_nullifier = 42;
    let wrong_nullifier = 99;
    let zero_sibling = 0;

    let mut path: [Field; 32] = [0; 32];
    let indices: [u1; 32] = [0; 32];

    // Compute root for the real nullifier
    let epoch_root = compute_merkle_root(real_nullifier, path, indices);

    // Try to prove inclusion with a different nullifier
    main(epoch_root, wrong_nullifier, path, indices);
}

#[test(should_fail_with = "Nullifier not in epoch tree")]
fn test_wrong_path_fails() {
    let nullifier = 42;

    let mut path: [Field; 32] = [0; 32];
    let indices: [u1; 32] = [0; 32];

    let epoch_root = compute_merkle_root(nullifier, path, indices);

    // Corrupt one sibling
    path[0] = 999;
    main(epoch_root, nullifier, path, indices);
}

#[test]
fn test_right_child_path() {
    // Nullifier at index 1 (right child at level 0)
    let nullifier = 77;

    let mut path: [Field; 32] = [0; 32];
    let mut indices: [u1; 32] = [0; 32];
    indices[0] = 1; // right child at level 0
    path[0] = 55; // left sibling at level 0

    let epoch_root = compute_merkle_root(nullifier, path, indices);
    main(epoch_root, nullifier, path, indices);
}
