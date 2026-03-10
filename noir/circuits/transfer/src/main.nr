/// Transfer Circuit (2-input, 2-output)
///
/// Proves a valid private transfer: consumes two input notes and produces
/// two output notes, while proving:
///   1. Input notes exist in the Merkle tree
///   2. Nullifiers are correctly derived (domain-separated V2)
///   3. Output commitments are well-formed
///   4. Value is conserved (sum of inputs == sum of outputs)
///
/// Public inputs:
///   - merkle_root: Current Merkle tree root
///   - nullifier_0, nullifier_1: Nullifiers for consumed notes
///   - output_commitment_0, output_commitment_1: New note commitments
///   - chain_id: Domain separation chain identifier
///   - app_id: Domain separation application identifier
///
/// Private inputs:
///   - Input note preimages (secret, nonce, value) x2
///   - Merkle proofs (sibling path + leaf index) x2
///   - Output note preimages (secret, nonce, value) x2

use dep::std::hash::poseidon;

/// Depth of the Merkle tree
global TREE_DEPTH: u32 = 32;

/// Compute Poseidon-based Merkle root from a leaf and its sibling path
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

/// Compute domain-separated nullifier V2:
/// nullifier = Poseidon(Poseidon(secret, commitment), Poseidon(chain_id, app_id))
fn compute_nullifier_v2(secret: Field, commitment: Field, chain_id: Field, app_id: Field) -> Field {
    let inner = poseidon::bn254::hash_2([secret, commitment]);
    let domain = poseidon::bn254::hash_2([chain_id, app_id]);
    poseidon::bn254::hash_2([inner, domain])
}

fn main(
    // Public inputs
    merkle_root: pub Field,
    nullifier_0: pub Field,
    nullifier_1: pub Field,
    output_commitment_0: pub Field,
    output_commitment_1: pub Field,
    chain_id: pub Field,
    app_id: pub Field,

    // Private: Input note 0
    in_secret_0: Field,
    in_nonce_0: Field,
    in_value_0: Field,
    in_path_0: [Field; 32],
    in_indices_0: [u1; 32],

    // Private: Input note 1
    in_secret_1: Field,
    in_nonce_1: Field,
    in_value_1: Field,
    in_path_1: [Field; 32],
    in_indices_1: [u1; 32],

    // Private: Output note 0
    out_secret_0: Field,
    out_nonce_0: Field,
    out_value_0: Field,

    // Private: Output note 1
    out_secret_1: Field,
    out_nonce_1: Field,
    out_value_1: Field,
) {
    // ── 1. Verify input commitments and Merkle membership ──────────

    // Input note 0: commitment = Poseidon(secret, nonce, value)
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);
    let computed_root_0 = compute_merkle_root(in_commitment_0, in_path_0, in_indices_0);
    assert(computed_root_0 == merkle_root, "Input 0 not in Merkle tree");

    // Input note 1
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let computed_root_1 = compute_merkle_root(in_commitment_1, in_path_1, in_indices_1);
    assert(computed_root_1 == merkle_root, "Input 1 not in Merkle tree");

    // ── 2. Verify nullifiers (domain-separated V2) ────────────────

    let computed_nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);
    assert(nullifier_0 == computed_nul_0, "Invalid nullifier 0");

    let computed_nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);
    assert(nullifier_1 == computed_nul_1, "Invalid nullifier 1");

    // Nullifiers must be different (no self-spend)
    assert(nullifier_0 != nullifier_1, "Duplicate nullifiers");

    // ── 3. Verify output commitments ──────────────────────────────

    let computed_out_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);
    assert(output_commitment_0 == computed_out_0, "Invalid output commitment 0");

    let computed_out_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);
    assert(output_commitment_1 == computed_out_1, "Invalid output commitment 1");

    // ── 4. Value conservation ─────────────────────────────────────
    // sum(inputs) == sum(outputs)

    let total_in = in_value_0 + in_value_1;
    let total_out = out_value_0 + out_value_1;
    assert(total_in == total_out, "Value not conserved");
}
