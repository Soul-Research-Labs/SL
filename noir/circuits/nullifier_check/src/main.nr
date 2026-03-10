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
