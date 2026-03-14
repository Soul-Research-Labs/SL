// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoseidonHasher} from "../../contracts/libraries/PoseidonHasher.sol";

contract PoseidonHarness {
    function hash(uint256 a, uint256 b) external pure returns (uint256) {
        return PoseidonHasher.hash(a, b);
    }

    function hashSingle(uint256 a) external pure returns (uint256) {
        return PoseidonHasher.hashSingle(a);
    }
}

contract PoseidonFuzzTest is Test {
    PoseidonHarness harness;
    uint256 constant FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function setUp() public {
        harness = new PoseidonHarness();
    }

    /// Poseidon output must always be within the BN254 scalar field.
    function testFuzz_hashOutputInField(uint256 a, uint256 b) public view {
        a = bound(a, 0, FIELD - 1);
        b = bound(b, 0, FIELD - 1);
        uint256 result = harness.hash(a, b);
        assertTrue(result < FIELD, "hash output exceeds field modulus");
    }

    /// Hash must be deterministic for any input pair.
    function testFuzz_hashDeterministic(uint256 a, uint256 b) public view {
        a = bound(a, 0, FIELD - 1);
        b = bound(b, 0, FIELD - 1);
        assertEq(harness.hash(a, b), harness.hash(a, b));
    }

    /// Varying one input should (almost certainly) change the output.
    function testFuzz_hashSensitivity(uint256 a, uint256 b) public view {
        a = bound(a, 0, FIELD - 2);
        b = bound(b, 0, FIELD - 1);
        uint256 h1 = harness.hash(a, b);
        uint256 h2 = harness.hash(a + 1, b);
        // Collision probability 1/FIELD ≈ 0 — safe to assert inequality
        assertTrue(h1 != h2, "hash collision with adjacent inputs");
    }

    /// Hash must be non-commutative (except for unlikely collisions).
    function testFuzz_hashNonCommutative(uint256 a, uint256 b) public view {
        a = bound(a, 0, FIELD - 1);
        b = bound(b, 0, FIELD - 1);
        vm.assume(a != b);
        uint256 h1 = harness.hash(a, b);
        uint256 h2 = harness.hash(b, a);
        assertTrue(
            h1 != h2,
            "hash(a,b) == hash(b,a) -- broken non-commutativity"
        );
    }

    /// hashSingle output must be in field.
    function testFuzz_hashSingleInField(uint256 a) public view {
        a = bound(a, 0, FIELD - 1);
        uint256 result = harness.hashSingle(a);
        assertTrue(result < FIELD, "hashSingle output exceeds field modulus");
    }
}
