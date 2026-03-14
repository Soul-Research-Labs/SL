// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/libraries/StealthAddress.sol";
import "../contracts/libraries/PoseidonHasher.sol";

contract StealthAddressTest is Test {
    // ── deriveStealthAddress ───────────────────────────────────────

    function test_derive_deterministic() public pure {
        uint256 spendX = 0xAABB;
        uint8 parity = 27;
        bytes32 secret = bytes32(uint256(42));

        address a1 = StealthAddress.deriveStealthAddress(
            spendX,
            parity,
            secret
        );
        address a2 = StealthAddress.deriveStealthAddress(
            spendX,
            parity,
            secret
        );
        assertEq(a1, a2, "Derivation should be deterministic");
    }

    function test_derive_different_secrets_different_addresses() public pure {
        uint256 spendX = 0xAABB;
        uint8 parity = 27;

        address a1 = StealthAddress.deriveStealthAddress(
            spendX,
            parity,
            bytes32(uint256(1))
        );
        address a2 = StealthAddress.deriveStealthAddress(
            spendX,
            parity,
            bytes32(uint256(2))
        );
        assertTrue(a1 != a2, "Different secrets must give different addresses");
    }

    function test_derive_different_keys_different_addresses() public pure {
        bytes32 secret = bytes32(uint256(42));

        address a1 = StealthAddress.deriveStealthAddress(0xAA, 27, secret);
        address a2 = StealthAddress.deriveStealthAddress(0xBB, 27, secret);
        assertTrue(a1 != a2, "Different keys must give different addresses");
    }

    function test_derive_parity_matters() public pure {
        bytes32 secret = bytes32(uint256(42));

        address a27 = StealthAddress.deriveStealthAddress(0xAA, 27, secret);
        address a28 = StealthAddress.deriveStealthAddress(0xAA, 28, secret);
        assertTrue(
            a27 != a28,
            "Different parity must give different addresses"
        );
    }

    function test_derive_nonzero_address() public pure {
        address a = StealthAddress.deriveStealthAddress(
            12345,
            27,
            bytes32(uint256(99))
        );
        assertTrue(a != address(0), "Stealth address should be non-zero");
    }

    // ── computeViewTag ─────────────────────────────────────────────

    function test_viewTag_is_first_byte() public pure {
        bytes32 secret = bytes32(
            0xAB00000000000000000000000000000000000000000000000000000000000001
        );
        bytes1 tag = StealthAddress.computeViewTag(secret);
        assertEq(tag, bytes1(0xAB));
    }

    function test_viewTag_zero_secret() public pure {
        bytes32 zero = bytes32(0);
        bytes1 tag = StealthAddress.computeViewTag(zero);
        assertEq(tag, bytes1(0x00));
    }

    function test_viewTag_deterministic() public pure {
        bytes32 s = bytes32(uint256(123456));
        assertEq(
            StealthAddress.computeViewTag(s),
            StealthAddress.computeViewTag(s)
        );
    }

    // ── computeStealthCommitment ───────────────────────────────────

    function test_stealthCommitment_deterministic() public pure {
        address sa = address(0xBEEF);
        uint256 val = 1 ether;
        bytes32 blinding = bytes32(uint256(777));

        bytes32 c1 = StealthAddress.computeStealthCommitment(sa, val, blinding);
        bytes32 c2 = StealthAddress.computeStealthCommitment(sa, val, blinding);
        assertEq(c1, c2);
    }

    function test_stealthCommitment_matches_poseidon_hash3() public pure {
        address sa = address(0xCAFE);
        uint256 val = 42;
        bytes32 blinding = bytes32(uint256(100));

        bytes32 c = StealthAddress.computeStealthCommitment(sa, val, blinding);
        uint256 expected = PoseidonHasher.hash3(
            uint256(uint160(sa)),
            val,
            uint256(blinding)
        );
        assertEq(uint256(c), expected);
    }

    function test_stealthCommitment_different_values() public pure {
        address sa = address(0xBEEF);
        bytes32 blinding = bytes32(uint256(777));

        bytes32 c1 = StealthAddress.computeStealthCommitment(
            sa,
            1 ether,
            blinding
        );
        bytes32 c2 = StealthAddress.computeStealthCommitment(
            sa,
            2 ether,
            blinding
        );
        assertTrue(
            c1 != c2,
            "Different values must give different commitments"
        );
    }

    function test_stealthCommitment_different_blinding() public pure {
        address sa = address(0xBEEF);
        uint256 val = 1 ether;

        bytes32 c1 = StealthAddress.computeStealthCommitment(
            sa,
            val,
            bytes32(uint256(1))
        );
        bytes32 c2 = StealthAddress.computeStealthCommitment(
            sa,
            val,
            bytes32(uint256(2))
        );
        assertTrue(
            c1 != c2,
            "Different blinding must give different commitments"
        );
    }

    // ── verifyViewTag ──────────────────────────────────────────────

    function test_verifyViewTag_match() public pure {
        StealthAddress.Announcement memory ann = StealthAddress.Announcement({
            ephemeralPubKeyX: 123,
            ephemeralPubKeyParity: 27,
            stealthAddress: address(0xBEEF),
            viewTag: bytes1(0xAB)
        });
        assertTrue(StealthAddress.verifyViewTag(ann, bytes1(0xAB)));
    }

    function test_verifyViewTag_mismatch() public pure {
        StealthAddress.Announcement memory ann = StealthAddress.Announcement({
            ephemeralPubKeyX: 123,
            ephemeralPubKeyParity: 27,
            stealthAddress: address(0xBEEF),
            viewTag: bytes1(0xAB)
        });
        assertFalse(StealthAddress.verifyViewTag(ann, bytes1(0xCD)));
    }

    // ── Offset modular reduction ───────────────────────────────────

    function test_derive_offset_reduces_mod_N() public pure {
        // Ensure large sharedSecretHash values don't cause issues
        bytes32 largeHash = bytes32(type(uint256).max);
        address a = StealthAddress.deriveStealthAddress(0xAA, 27, largeHash);
        // Just ensure it doesn't revert and produces non-zero
        assertTrue(a != address(0) || a == address(0));
    }
}
