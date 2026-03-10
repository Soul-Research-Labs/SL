/// Withdraw Circuit
///
/// Proves a valid withdrawal from the privacy pool. Consumes an input note
/// and produces a public withdrawal, optionally with change back to the pool.
///
/// Public inputs:
///   - merkle_root: Current Merkle tree root
///   - nullifier: Nullifier for the consumed note
///   - recipient: Withdrawal recipient address (as Field)
///   - withdraw_value: Amount being withdrawn publicly
///   - change_commitment: Commitment for remaining value (0 if full withdrawal)
///   - chain_id: Domain separation chain identifier
///   - app_id: Domain separation application identifier
///
/// Private inputs:
///   - Note preimage (secret, nonce, value)
///   - Merkle proof (sibling path + leaf index)
///   - Change note preimage (secret, nonce, value) — if partial withdrawal

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

fn compute_nullifier_v2(secret: Field, commitment: Field, chain_id: Field, app_id: Field) -> Field {
    let inner = poseidon::bn254::hash_2([secret, commitment]);
    let domain = poseidon::bn254::hash_2([chain_id, app_id]);
    poseidon::bn254::hash_2([inner, domain])
}

fn main(
    // Public inputs
    merkle_root: pub Field,
    nullifier: pub Field,
    recipient: pub Field,
    withdraw_value: pub Field,
    change_commitment: pub Field,
    chain_id: pub Field,
    app_id: pub Field,

    // Private: Input note
    in_secret: Field,
    in_nonce: Field,
    in_value: Field,
    in_path: [Field; 32],
    in_indices: [u1; 32],

    // Private: Change note (remaining value returned to pool)
    change_secret: Field,
    change_nonce: Field,
    change_value: Field,
) {
    // ── 1. Verify input note exists in Merkle tree ────────────────

    let in_commitment = poseidon::bn254::hash_3([in_secret, in_nonce, in_value]);
    let computed_root = compute_merkle_root(in_commitment, in_path, in_indices);
    assert(computed_root == merkle_root, "Input note not in Merkle tree");

    // ── 2. Verify nullifier ───────────────────────────────────────

    let computed_nullifier = compute_nullifier_v2(in_secret, in_commitment, chain_id, app_id);
    assert(nullifier == computed_nullifier, "Invalid nullifier");

    // ── 3. Withdrawal amount must be positive ─────────────────────

    assert(withdraw_value != 0, "Withdrawal value must be non-zero");

    // ── 4. Recipient must be non-zero ─────────────────────────────

    assert(recipient != 0, "Invalid recipient address");

    // ── 5. Value conservation: input == withdraw + change ─────────

    assert(in_value == withdraw_value + change_value, "Value not conserved");

    // ── 6. Verify change commitment (if any) ──────────────────────
    //    If change_value > 0, the change_commitment must be well-formed.
    //    If change_value == 0, change_commitment must be 0 (no change note).

    if change_value != 0 {
        let computed_change = poseidon::bn254::hash_3([change_secret, change_nonce, change_value]);
        assert(change_commitment == computed_change, "Invalid change commitment");
    } else {
        assert(change_commitment == 0, "Change commitment must be zero for full withdrawal");
    }

    // ── 7. Prevent self-referential withdrawal ────────────────────

    assert(in_secret != 0, "Secret must be non-zero");
}
