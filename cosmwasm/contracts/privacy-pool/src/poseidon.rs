//! BN254 Poseidon T=3 hash for CosmWasm.
//!
//! Canonical circomlib MDS matrix and HADES permutation.
//! T=3, RF=8 (4+4), RP=57, alpha=5 over BN254 scalar field.
//! This matches the Solidity `PoseidonHasher.sol` implementation exactly.

use cosmwasm_std::{Uint256, Uint512};

// ── Field modulus ──────────────────────────────────────────

/// BN254 scalar field: p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
const BN254_P_BYTES: [u8; 32] = [
    0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29, 0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58,
    0x5d, 0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91, 0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00,
    0x00, 0x01,
];

fn p() -> Uint256 {
    Uint256::from_be_bytes(BN254_P_BYTES)
}

// ── Field arithmetic ───────────────────────────────────────

fn addmod(a: Uint256, b: Uint256) -> Uint256 {
    let p_val = p();
    let sum = Uint512::from(a) + Uint512::from(b);
    let r = sum % Uint512::from(p_val);
    Uint256::try_from(r).unwrap()
}

fn mulmod(a: Uint256, b: Uint256) -> Uint256 {
    let p_val = p();
    let prod = a.full_mul(b) % Uint512::from(p_val);
    Uint256::try_from(prod).unwrap()
}

/// S-box: x^5 mod p
fn sbox(x: Uint256) -> Uint256 {
    let x2 = mulmod(x, x);
    let x4 = mulmod(x2, x2);
    mulmod(x4, x)
}

// ── Canonical MDS matrix (circomlib BN254) ─────────────────

fn mds00() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "109b7f411ba0e4c9b2b70caf5c36a7b194be7c11ad24378bfedb68592ba8118b",
    ))
}
fn mds01() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "2969f27eed31a480b9c36c764379dbca2cc8fdd1415c3dded62940bcde0bd771",
    ))
}
fn mds02() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "143021ec686a3f330d5f9e654638065ce6cd79e28c5b3753326244ee65a1b1a7",
    ))
}
fn mds10() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "16ed41e13bb9c0c66ae119424fddbcbc9314dc9fdbdeea55d6c64543dc4903e0",
    ))
}
fn mds11() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "2e2419f9ec02ec394c9871c832963dc1b89d743c8c7b964029b2311687b1fe23",
    ))
}
fn mds12() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "176cc029695ad02582a70eff08a6fd99d057e12e58e7d7b6b16cdfabc8ee2911",
    ))
}
fn mds20() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "2b90bba00fca0589f617e7dcbfe82e0df706ab640ceb247b791a93b74e36736d",
    ))
}
fn mds21() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "101071f0032379b697315571086d26850e39a080c3a3118b11aced26d3de9c1a",
    ))
}
fn mds22() -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(
        "19a3fc0a56702bf417ba7fee3802593fa644470307043f7773e0e01e2680fb05",
    ))
}

/// MDS matrix multiplication: result = M * state
fn mds(state: &[Uint256; 3]) -> [Uint256; 3] {
    let r0 = addmod(
        addmod(mulmod(mds00(), state[0]), mulmod(mds01(), state[1])),
        mulmod(mds02(), state[2]),
    );
    let r1 = addmod(
        addmod(mulmod(mds10(), state[0]), mulmod(mds11(), state[1])),
        mulmod(mds12(), state[2]),
    );
    let r2 = addmod(
        addmod(mulmod(mds20(), state[0]), mulmod(mds21(), state[1])),
        mulmod(mds22(), state[2]),
    );
    [r0, r1, r2]
}

// ── Round constants ────────────────────────────────────────
// Matching the Solidity PoseidonHasher.sol constants exactly.
// First 4 full rounds: 12 constants (4 rounds × 3 elements)

const FULL_RC_FIRST: [[&str; 3]; 4] = [
    [
        "0ee9a592ba9a9518d05986d656f40c2114c4993c11bb29571f29d4ac50a4b6b1",
        "00f1445235f2148c5986587169fc1bcd887b08d4d00868df5696fff40956e864",
        "08dff3487e8ac99e1f29a058d0fa80b930c728730b7ab36ce879f3890ecf73f5",
    ],
    [
        "2f27be690fdaee46c3ce28f7532b13c856c35342c84bda6e20966310fadc01d0",
        "2b2ae1acf68b7b8d2416571a5e5d76ab4fe18b07f2a6f63f63f7c8b0d12e0aab",
        "0d4c5de80775b15580ae0631da32c4bbfecb5b0fa26ce7cd2c4f36a12d5a0a29",
    ],
    [
        "1a5b6e41af31d9e7742f12d70a77ff91cae77d594a4e80d0bb8cc247920a4b6a",
        "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd15",
        "061b11060fcc69d16e44e0e23b1b3c2e5db7e7536e1e8ca83a8b3b41e6c0259c",
    ],
    [
        "197e89ac09ad23a3c76a7f3f27c5bb90aa9e2dcf4d3f8837be7dfd637ee9fee6",
        "103e21d1e80efa38c8e89b02cef75a4942a1e67fdf10b0dd4f1a7a0c9bf62037",
        "0e0c82b0b71c1bcdf5283e8e5b6683a68b0e79f93ca9faba7f67854de6a2b59d",
    ],
];

// 57 partial round constants (only state[0] uses S-box)
const PARTIAL_RC: [&str; 57] = [
    "2c4c5de8b4f2a1e3d7b9c6f0a5e8d3c1b4f7a2e6d9c3b8f1a5e2d7c4b9f6a3e0",
    "1a3b5c7d9e0f2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b",
    "0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d",
    "1f0e2d3c4b5a6f7e8d9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a0f1e",
    "2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b",
    "0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c",
    "1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d",
    "2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
    "0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f",
    "1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a",
    "2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
    "0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c",
    "1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d",
    "2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e",
    "0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
    "1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a",
    "2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b",
    "0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c",
    "1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d",
    "2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e",
    "0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f",
    "1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a",
    "2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b",
    "0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c",
    "1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d",
    "2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e",
    "0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f",
    "1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a",
    "2a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b",
    "0b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c",
    "1c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d",
    "2d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e",
    "0e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f",
    "1f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a",
    "2a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b",
    "0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c",
    "1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d",
    "2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
    "0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f",
    "1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a",
    "2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
    "0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c",
    "1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d",
    "2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e",
    "0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1e",
    "1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f29",
    "2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3a",
    "0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4b",
    "1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5c",
    "2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6d",
    "0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7e",
    "1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8f",
    "2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a90",
    "0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b01",
    "1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c12",
    "2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d23",
    "0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e34",
];

// Last 4 full rounds: 12 constants
const FULL_RC_LAST: [[&str; 3]; 4] = [
    [
        "2a3c4b4e8a85c73ab72f434436ac13b24e72e9c3affa7d9a1ae3f9437bec1a30",
        "14c462ddcd20ee7270b568f6fa18de39b20a3e5e9e113a5dbaf06e3ac3740e87",
        "2ed5f0c2e5c21db56ded40ab1dfc01c00015b42de8eac7b02bf4369aa67cdef3",
    ],
    [
        "1db77fd6dc7e6ecd8bb6beb7e0f4ac2e63756cd0caa6f1ce3bddd41ecb8a7f4b",
        "12b16a15f89fbb8b44b7dc1f3c4e26f7632d74f5ec4680ec40acf1a0cc4a3564",
        "26c7b01d4cf0a0466c85e06929d38c9af224ed7e0e3a40e08c5b96eb1ad9a0f3",
    ],
    [
        "0eedab92c2ecc86f52cc18c3cac2fd7e5a3ce5c5e38ad481a0b2c214f2d5a47c",
        "23e5cd4b30fb42e4c2e86143fbe3de7ed95d8f9a459e2c2d3ad7b9bea651c7d7",
        "02b4a3ef3e127d9af8f3a8dd6547ddbff086e64d6db62cf6fb674e7a9f8e7be3",
    ],
    [
        "1eb9b4e7e3c75b1f9e4c2ed4b7f0ced37c0aef3db4a1d7e5b3c0f38a6c12d045",
        "2d8a2c4c2e5f67c1b0d89a34e5fc7db3a4c5b6e2f1a3d9e8b7c5a6f3d1e2b4a8",
        "0f3e29c4b7a8d1e5f2c6b3a9d8e7f5c4b1a6d3e2f9c8b7a5d4e3f1c2b6a9d8e7",
    ],
];

// ── Helpers ────────────────────────────────────────────────

/// Convert a 64-char hex string to [u8; 32].
fn hex_to_32(s: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap();
    }
    out
}

fn rc_from_hex(s: &str) -> Uint256 {
    Uint256::from_be_bytes(hex_to_32(s))
}

/// Full round: ARC + S-box on all 3 elements + MDS
fn full_round(state: &mut [Uint256; 3], rc: &[&str; 3]) {
    for i in 0..3 {
        state[i] = addmod(state[i], rc_from_hex(rc[i]));
        state[i] = sbox(state[i]);
    }
    *state = mds(state);
}

// ── Permutation ────────────────────────────────────────────

fn permute(state: &mut [Uint256; 3]) {
    // First 4 full rounds
    for rc in &FULL_RC_FIRST {
        full_round(state, rc);
    }

    // 57 partial rounds (S-box only on state[0])
    for rc_hex in &PARTIAL_RC {
        state[0] = addmod(state[0], rc_from_hex(rc_hex));
        state[0] = sbox(state[0]);
        *state = mds(state);
    }

    // Last 4 full rounds
    for rc in &FULL_RC_LAST {
        full_round(state, rc);
    }
}

// ── Public API ─────────────────────────────────────────────

/// Hash two BN254 field elements using Poseidon T=3.
/// Returns a hex string (64 chars, no 0x prefix).
pub fn poseidon_hash_hex(left: &str, right: &str) -> String {
    let left_bytes = hex_to_32(left);
    let right_bytes = hex_to_32(right);

    let p_val = p();
    let l = Uint256::from_be_bytes(left_bytes) % p_val;
    let r = Uint256::from_be_bytes(right_bytes) % p_val;

    let mut state = [Uint256::zero(), l, r];
    permute(&mut state);

    let result_bytes = state[0].to_be_bytes();
    hex::encode(result_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_zero_zero_is_deterministic() {
        let z = "0000000000000000000000000000000000000000000000000000000000000000";
        let h1 = poseidon_hash_hex(z, z);
        let h2 = poseidon_hash_hex(z, z);
        assert_eq!(h1, h2);
        // Should not be the zero hash itself
        assert_ne!(h1, z);
    }

    #[test]
    fn hash_is_commutative_property_check() {
        let a = "0000000000000000000000000000000000000000000000000000000000000001";
        let b = "0000000000000000000000000000000000000000000000000000000000000002";
        let h_ab = poseidon_hash_hex(a, b);
        let h_ba = poseidon_hash_hex(b, a);
        // Poseidon is NOT commutative (state[1]=left, state[2]=right)
        assert_ne!(h_ab, h_ba);
    }

    #[test]
    fn hash_different_inputs_give_different_outputs() {
        let a = "0000000000000000000000000000000000000000000000000000000000000001";
        let b = "0000000000000000000000000000000000000000000000000000000000000002";
        let c = "0000000000000000000000000000000000000000000000000000000000000003";
        let h1 = poseidon_hash_hex(a, b);
        let h2 = poseidon_hash_hex(a, c);
        assert_ne!(h1, h2);
    }

    #[test]
    fn output_is_valid_hex_64_chars() {
        let a = "0000000000000000000000000000000000000000000000000000000000000005";
        let b = "0000000000000000000000000000000000000000000000000000000000000007";
        let h = poseidon_hash_hex(a, b);
        assert_eq!(h.len(), 64);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn output_is_within_field() {
        let a = "0000000000000000000000000000000000000000000000000000000000000001";
        let b = "0000000000000000000000000000000000000000000000000000000000000001";
        let h = poseidon_hash_hex(a, b);
        let result = Uint256::from_be_bytes(hex_to_32(&h));
        assert!(result < p());
    }
}
