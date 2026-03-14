/// Deposit Circuit
///
/// Proves that a commitment is correctly formed from a secret and value,
/// without revealing either. This is the entry point into the privacy pool.
///
/// Public inputs:
///   - commitment: The Poseidon hash commitment being deposited
///   - value: The deposit amount (public for value matching)
///
/// Private inputs:
///   - secret: The depositor's secret key (blinding factor)
///   - nonce: Random nonce for commitment uniqueness
///
/// Constraints:
///   1. commitment == Poseidon(secret, nonce, value)
///   2. value > 0
///   3. secret != 0 (prevents trivial commitments)

use dep::std::hash::poseidon;

fn main(
    // Public inputs
    commitment: pub Field,
    value: pub Field,
    // Private inputs
    secret: Field,
    nonce: Field,
) {
    // 1. Verify commitment is correctly formed
    //    commitment = Poseidon(secret, nonce, value)
    let computed_commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    assert(commitment == computed_commitment, "Invalid commitment preimage");

    // 2. Value must be positive
    //    We check value != 0 (Noir Field is unsigned in BN254)
    assert(value != 0, "Deposit value must be non-zero");

    // 3. Secret must not be zero (prevents trivial/guessable commitments)
    assert(secret != 0, "Secret must be non-zero");
}

#[test]
fn test_valid_deposit() {
    let secret = 12345;
    let nonce = 67890;
    let value = 1000000000; // 1 token in smallest denomination

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);

    main(commitment, value, secret, nonce);
}

#[test(should_fail_with = "Deposit value must be non-zero")]
fn test_zero_value_fails() {
    let secret = 12345;
    let nonce = 67890;
    let value = 0;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);

    main(commitment, value, secret, nonce);
}

#[test(should_fail_with = "Secret must be non-zero")]
fn test_zero_secret_fails() {
    let secret = 0;
    let nonce = 67890;
    let value = 1000;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);

    main(commitment, value, secret, nonce);
}

#[test(should_fail_with = "Invalid commitment preimage")]
fn test_wrong_commitment_fails() {
    let secret = 12345;
    let nonce = 67890;
    let value = 1000;

    // Provide a wrong commitment
    let fake_commitment = poseidon::bn254::hash_3([secret, nonce, 9999]);

    main(fake_commitment, value, secret, nonce);
}

// ── Additional edge-case tests ─────────────────────────────

#[test(should_fail_with = "Invalid commitment preimage")]
fn test_wrong_nonce_fails() {
    let secret = 12345;
    let nonce = 67890;
    let value = 1000;

    // Commitment built with correct nonce, but wrong nonce supplied to main
    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    let wrong_nonce = 11111;

    main(commitment, value, secret, wrong_nonce);
}

#[test(should_fail_with = "Invalid commitment preimage")]
fn test_wrong_secret_preimage_fails() {
    let secret = 12345;
    let nonce = 67890;
    let value = 1000;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    let wrong_secret = 99999;

    main(commitment, value, wrong_secret, nonce);
}

#[test(should_fail_with = "Invalid commitment preimage")]
fn test_mismatched_public_value_fails() {
    // Commitment is valid for value=1000, but public value claims 2000
    let secret = 12345;
    let nonce = 67890;
    let real_value = 1000;

    let commitment = poseidon::bn254::hash_3([secret, nonce, real_value]);
    let claimed_value = 2000;

    main(commitment, claimed_value, secret, nonce);
}

#[test]
fn test_zero_nonce_allowed() {
    // Nonce = 0 is not prohibited by the circuit
    let secret = 12345;
    let nonce = 0;
    let value = 500;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    main(commitment, value, secret, nonce);
}

#[test]
fn test_large_field_values() {
    // Test with large (but valid) field elements
    let secret = 0xFFFFFFFFFFFFFFFF;
    let nonce = 0xAAAAAAAAAAAAAAAA;
    let value = 0x1234567890ABCDEF;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    main(commitment, value, secret, nonce);
}

#[test]
fn test_value_one_wei() {
    // Smallest possible valid deposit
    let secret = 42;
    let nonce = 7;
    let value = 1;

    let commitment = poseidon::bn254::hash_3([secret, nonce, value]);
    main(commitment, value, secret, nonce);
}
