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
