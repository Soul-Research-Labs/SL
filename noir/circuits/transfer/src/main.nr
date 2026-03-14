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

// ── Tests ──────────────────────────────────────────────────

// Helper: build a Merkle root from a single leaf at index 0
fn build_root_for_leaf(leaf: Field) -> (Field, [Field; 32], [u1; 32]) {
    let path: [Field; 32] = [0; 32];
    let indices: [u1; 32] = [0; 32];
    let root = compute_merkle_root(leaf, path, indices);
    (root, path, indices)
}

#[test]
fn test_valid_transfer() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);

    // Both notes in separate Merkle trees — for test simplicity, use same root
    // (each note is the only leaf at index 0)
    let (root_0, path_0, indices_0) = build_root_for_leaf(in_commitment_0);
    let (root_1, path_1, indices_1) = build_root_for_leaf(in_commitment_1);

    // Compute nullifiers
    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    // Output notes: total 1000 = 600 + 400
    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 600;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 400;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    // Both inputs share the same root (simplification for test)
    // In practice they'd share the same tree
    main(
        root_0, nul_0, nul_1,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path_0, indices_0,
        in_secret_1, in_nonce_1, in_value_1, path_0, indices_0,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Value not conserved")]
fn test_transfer_value_mismatch_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);

    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);

    // Second input same secret but different nonce for distinct nullifier
    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 300;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    // Output values don't match input sum (800 != 900)
    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 400;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    main(
        root, nul_0, nul_1,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Invalid nullifier 0")]
fn test_transfer_wrong_nullifier_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);

    // Wrong nullifier
    let wrong_nul = 9999;

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    main(
        root, wrong_nul, nul_1,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Invalid output commitment 0")]
fn test_transfer_wrong_output_commitment_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);

    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    // Wrong commitment (doesn't match preimage)
    let fake_out_commitment_0 = 12345;

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    main(
        root, nul_0, nul_1,
        fake_out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

// ── Additional edge-case tests ─────────────────────────────

#[test(should_fail_with = "Duplicate nullifiers")]
fn test_duplicate_nullifiers_fails() {
    let chain_id = 43113;
    let app_id = 1;

    // Use identical notes → identical nullifiers
    let in_secret = 111;
    let in_nonce = 222;
    let in_value = 500;
    let in_commitment = poseidon::bn254::hash_3([in_secret, in_nonce, in_value]);

    let (root, path, indices) = build_root_for_leaf(in_commitment);
    let nul = compute_nullifier_v2(in_secret, in_commitment, chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    main(
        root, nul, nul,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret, in_nonce, in_value, path, indices,
        in_secret, in_nonce, in_value, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Input 1 not in Merkle tree")]
fn test_input1_not_in_tree_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);
    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);

    // Second input with different secret → different commitment → different root
    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    // Use a corrupted path for input 1 that won't match root
    let mut bad_path: [Field; 32] = [0; 32];
    bad_path[0] = 999999;

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    main(
        root, nul_0, nul_1,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, bad_path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Invalid output commitment 1")]
fn test_transfer_wrong_output_commitment_1_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);
    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    // Wrong output commitment 1
    let fake_out_commitment_1 = 99999;

    main(
        root, nul_0, nul_1,
        out_commitment_0, fake_out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        555, 666, 500,
    );
}

#[test(should_fail_with = "Invalid nullifier 0")]
fn test_transfer_wrong_chain_id_nullifier_fails() {
    // Nullifiers computed with chain_id=1 but circuit given chain_id=43113
    let real_chain_id = 43113;
    let wrong_chain_id = 1;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (root, path, indices) = build_root_for_leaf(in_commitment_0);

    // Compute nullifiers with wrong chain_id
    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, wrong_chain_id, app_id);

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, wrong_chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    // Pass real_chain_id to main but nullifiers were computed with wrong_chain_id
    main(
        root, nul_0, nul_1,
        out_commitment_0, out_commitment_1,
        real_chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}

#[test(should_fail_with = "Input 0 not in Merkle tree")]
fn test_transfer_wrong_merkle_root_fails() {
    let chain_id = 43113;
    let app_id = 1;

    let in_secret_0 = 111;
    let in_nonce_0 = 222;
    let in_value_0 = 500;
    let in_commitment_0 = poseidon::bn254::hash_3([in_secret_0, in_nonce_0, in_value_0]);

    let (_, path, indices) = build_root_for_leaf(in_commitment_0);
    let nul_0 = compute_nullifier_v2(in_secret_0, in_commitment_0, chain_id, app_id);

    let in_secret_1 = 333;
    let in_nonce_1 = 444;
    let in_value_1 = 500;
    let in_commitment_1 = poseidon::bn254::hash_3([in_secret_1, in_nonce_1, in_value_1]);
    let nul_1 = compute_nullifier_v2(in_secret_1, in_commitment_1, chain_id, app_id);

    let out_secret_0 = 555;
    let out_nonce_0 = 666;
    let out_value_0 = 500;
    let out_commitment_0 = poseidon::bn254::hash_3([out_secret_0, out_nonce_0, out_value_0]);

    let out_secret_1 = 777;
    let out_nonce_1 = 888;
    let out_value_1 = 500;
    let out_commitment_1 = poseidon::bn254::hash_3([out_secret_1, out_nonce_1, out_value_1]);

    // Fabricated root that doesn't match any proof
    let fake_root = 12345;

    main(
        fake_root, nul_0, nul_1,
        out_commitment_0, out_commitment_1,
        chain_id, app_id,
        in_secret_0, in_nonce_0, in_value_0, path, indices,
        in_secret_1, in_nonce_1, in_value_1, path, indices,
        out_secret_0, out_nonce_0, out_value_0,
        out_secret_1, out_nonce_1, out_value_1,
    );
}
