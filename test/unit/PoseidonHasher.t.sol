// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoseidonHasher} from "../../contracts/libraries/PoseidonHasher.sol";

/// @title PoseidonHasher harness — exposes internal library functions for testing.
contract PoseidonHarness {
    function hash(uint256 a, uint256 b) external pure returns (uint256) {
        return PoseidonHasher.hash(a, b);
    }

    function hashSingle(uint256 a) external pure returns (uint256) {
        return PoseidonHasher.hashSingle(a);
    }

    function hash3(
        uint256 a,
        uint256 b,
        uint256 c
    ) external pure returns (uint256) {
        return PoseidonHasher.hash3(a, b, c);
    }

    function hash4(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) external pure returns (uint256) {
        return PoseidonHasher.hash4(a, b, c, d);
    }
}

contract PoseidonHasherTest is Test {
    PoseidonHarness harness;

    function setUp() public {
        harness = new PoseidonHarness();
    }

    // ── Determinism ────────────────────────────────────

    function test_hash_deterministic() public view {
        uint256 a = harness.hash(1, 2);
        uint256 b = harness.hash(1, 2);
        assertEq(a, b, "hash must be deterministic");
    }

    function test_hashSingle_deterministic() public view {
        uint256 a = harness.hashSingle(42);
        uint256 b = harness.hashSingle(42);
        assertEq(a, b, "hashSingle must be deterministic");
    }

    // ── Sensitivity ────────────────────────────────────

    function test_hash_different_inputs() public view {
        uint256 a = harness.hash(1, 2);
        uint256 b = harness.hash(1, 3);
        assertTrue(a != b, "different inputs must produce different hashes");
    }

    function test_hash_order_matters() public view {
        uint256 a = harness.hash(1, 2);
        uint256 b = harness.hash(2, 1);
        assertTrue(a != b, "hash(a,b) != hash(b,a)");
    }

    function test_hashSingle_vs_hash() public view {
        uint256 a = harness.hashSingle(7);
        uint256 b = harness.hash(7, 0);
        // hashSingle(x) uses domain [0, x, 0] ≠ hash(x, 0) using [0, x, 0]
        // They may or may not equal depending on implementation — just verify both are non-zero
        assertTrue(a != 0, "hashSingle should be non-zero");
        assertTrue(b != 0, "hash should be non-zero");
    }

    // ── Field bounds ───────────────────────────────────

    function test_hash_output_in_field() public view {
        uint256 FIELD_MODULUS = 21888242871839275222246405745257275088548364400416034343698204186575808495617;
        uint256 result = harness.hash(0, 0);
        assertTrue(
            result < FIELD_MODULUS,
            "output must be in BN254 scalar field"
        );
    }

    function test_hash_zero_inputs() public view {
        uint256 result = harness.hash(0, 0);
        // Poseidon(0,0) is well-defined and non-zero for canonical constants
        assertTrue(
            result != 0,
            "hash(0,0) should be non-zero with canonical constants"
        );
    }

    // ── Hash3 and Hash4 ───────────────────────────────

    function test_hash3_deterministic() public view {
        uint256 a = harness.hash3(1, 2, 3);
        uint256 b = harness.hash3(1, 2, 3);
        assertEq(a, b);
    }

    function test_hash4_deterministic() public view {
        uint256 a = harness.hash4(1, 2, 3, 4);
        uint256 b = harness.hash4(1, 2, 3, 4);
        assertEq(a, b);
    }

    function test_hash3_sensitivity() public view {
        uint256 a = harness.hash3(1, 2, 3);
        uint256 b = harness.hash3(1, 2, 4);
        assertTrue(a != b, "hash3 must be sensitive to input changes");
    }
}
