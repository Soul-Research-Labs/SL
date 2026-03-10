/// Stealth Address Circuit
///
/// Proves that a stealth address was correctly derived from a meta-address
/// and an ephemeral key, without revealing the recipient's spending key.
///
/// Protocol (simplified DKSAP-style):
///   1. Recipient publishes stealth meta-address: (spendPubKey, viewPubKey)
///   2. Sender generates ephemeral keypair (ephPriv, ephPub)
///   3. Shared secret S = Poseidon(ephPriv, viewPubKey)
///   4. Stealth address = Poseidon(spendPubKey, S)
///   5. View tag = S mod 2^16 (first 16 bits for fast scanning)
///
/// Public inputs:
///   - stealth_address: The derived stealth address
///   - ephemeral_pub_key: The ephemeral public key (published on-chain)
///   - view_tag: Truncated shared secret for fast scanning
///
/// Private inputs:
///   - spend_pub_key: Recipient's spend public key
///   - view_pub_key: Recipient's view public key
///   - ephemeral_priv_key: Sender's ephemeral private key
///
/// Constraints:
///   1. shared_secret = Poseidon(ephemeral_priv_key, view_pub_key)
///   2. ephemeral_pub_key = Poseidon(ephemeral_priv_key, generator)
///   3. stealth_address = Poseidon(spend_pub_key, shared_secret)
///   4. view_tag matches truncation of shared_secret
///   5. All keys are non-zero

use dep::std::hash::poseidon;

/// Generator constant for ephemeral key derivation (domain separator)
global GENERATOR: Field = 0x0000000000000000000000000000000000000000000000000000000000000007;

/// Mask for extracting the 16-bit view tag from shared secret
global VIEW_TAG_MASK: Field = 0xFFFF;

fn main(
    // Public inputs
    stealth_address: pub Field,
    ephemeral_pub_key: pub Field,
    view_tag: pub Field,
    // Private inputs
    spend_pub_key: Field,
    view_pub_key: Field,
    ephemeral_priv_key: Field,
) {
    // 1. Keys must be non-zero
    assert(spend_pub_key != 0, "Spend public key must be non-zero");
    assert(view_pub_key != 0, "View public key must be non-zero");
    assert(ephemeral_priv_key != 0, "Ephemeral private key must be non-zero");

    // 2. Derive ephemeral public key: ephPub = Poseidon(ephPriv, GENERATOR)
    let computed_eph_pub = poseidon::bn254::hash_2([ephemeral_priv_key, GENERATOR]);
    assert(
        ephemeral_pub_key == computed_eph_pub,
        "Ephemeral public key mismatch"
    );

    // 3. Compute shared secret: S = Poseidon(ephPriv, viewPubKey)
    let shared_secret = poseidon::bn254::hash_2([ephemeral_priv_key, view_pub_key]);

    // 4. Derive stealth address: addr = Poseidon(spendPubKey, S)
    let computed_stealth = poseidon::bn254::hash_2([spend_pub_key, shared_secret]);
    assert(
        stealth_address == computed_stealth,
        "Stealth address derivation mismatch"
    );

    // 5. Verify view tag: tag = S mod 2^16
    //    Use bit decomposition — extract lowest 16 bits
    let shared_bytes = shared_secret.to_be_bytes::<32>();
    // Last 2 bytes = lowest 16 bits
    let computed_tag = (shared_bytes[30] as Field) * 256 + (shared_bytes[31] as Field);
    assert(view_tag == computed_tag, "View tag mismatch");
}

#[test]
fn test_valid_stealth_derivation() {
    let spend_pub = 111222333;
    let view_pub = 444555666;
    let eph_priv = 777888999;

    let eph_pub = poseidon::bn254::hash_2([eph_priv, GENERATOR]);
    let shared_secret = poseidon::bn254::hash_2([eph_priv, view_pub]);
    let stealth_addr = poseidon::bn254::hash_2([spend_pub, shared_secret]);

    let shared_bytes = shared_secret.to_be_bytes::<32>();
    let tag = (shared_bytes[30] as Field) * 256 + (shared_bytes[31] as Field);

    main(stealth_addr, eph_pub, tag, spend_pub, view_pub, eph_priv);
}

#[test(should_fail_with = "Stealth address derivation mismatch")]
fn test_wrong_spend_key_fails() {
    let spend_pub = 111222333;
    let view_pub = 444555666;
    let eph_priv = 777888999;

    let eph_pub = poseidon::bn254::hash_2([eph_priv, GENERATOR]);
    let shared_secret = poseidon::bn254::hash_2([eph_priv, view_pub]);
    let stealth_addr = poseidon::bn254::hash_2([spend_pub, shared_secret]);

    let shared_bytes = shared_secret.to_be_bytes::<32>();
    let tag = (shared_bytes[30] as Field) * 256 + (shared_bytes[31] as Field);

    // Use wrong spend key
    let wrong_spend = 999999999;
    main(stealth_addr, eph_pub, tag, wrong_spend, view_pub, eph_priv);
}

#[test(should_fail_with = "Ephemeral public key mismatch")]
fn test_wrong_ephemeral_key_fails() {
    let spend_pub = 111222333;
    let view_pub = 444555666;
    let eph_priv = 777888999;

    let shared_secret = poseidon::bn254::hash_2([eph_priv, view_pub]);
    let stealth_addr = poseidon::bn254::hash_2([spend_pub, shared_secret]);

    let shared_bytes = shared_secret.to_be_bytes::<32>();
    let tag = (shared_bytes[30] as Field) * 256 + (shared_bytes[31] as Field);

    // Use mismatched ephemeral pub key
    let wrong_eph_pub = 123456789;
    main(stealth_addr, wrong_eph_pub, tag, spend_pub, view_pub, eph_priv);
}

#[test(should_fail_with = "Spend public key must be non-zero")]
fn test_zero_spend_key_fails() {
    let view_pub = 444555666;
    let eph_priv = 777888999;
    let eph_pub = poseidon::bn254::hash_2([eph_priv, GENERATOR]);

    main(0, eph_pub, 0, 0, view_pub, eph_priv);
}
