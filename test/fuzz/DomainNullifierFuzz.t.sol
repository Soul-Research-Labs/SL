// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {DomainNullifier} from "../../contracts/libraries/DomainNullifier.sol";
import {PoseidonHasher} from "../../contracts/libraries/PoseidonHasher.sol";

contract DomainNullifierHarness {
    function computeV1(uint256 sk, uint256 cm) external pure returns (uint256) {
        return DomainNullifier.computeV1(sk, cm);
    }

    function computeV2(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) external pure returns (uint256) {
        return DomainNullifier.computeV2(sk, cm, chainId, appId);
    }

    function computeDomainTag(
        uint256 chainId,
        uint256 appId
    ) external pure returns (uint256) {
        return DomainNullifier.computeDomainTag(chainId, appId);
    }

    function verifyV2(
        uint256 nullifier,
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) external pure returns (bool) {
        return DomainNullifier.verifyV2(nullifier, sk, cm, chainId, appId);
    }
}

contract DomainNullifierFuzzTest is Test {
    DomainNullifierHarness harness;

    uint256 constant FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function setUp() public {
        harness = new DomainNullifierHarness();
    }

    /// V2 nullifier must be deterministic.
    function testFuzz_v2Deterministic(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) public view {
        sk = bound(sk, 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainId = bound(chainId, 1, type(uint32).max);
        appId = bound(appId, 1, type(uint32).max);

        uint256 n1 = harness.computeV2(sk, cm, chainId, appId);
        uint256 n2 = harness.computeV2(sk, cm, chainId, appId);
        assertEq(n1, n2, "V2 nullifier not deterministic");
    }

    /// V2 verifyV2 must agree with computeV2.
    function testFuzz_verifyV2Consistency(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) public view {
        sk = bound(sk, 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainId = bound(chainId, 1, type(uint32).max);
        appId = bound(appId, 1, type(uint32).max);

        uint256 nullifier = harness.computeV2(sk, cm, chainId, appId);
        assertTrue(
            harness.verifyV2(nullifier, sk, cm, chainId, appId),
            "verifyV2 should return true for correct inputs"
        );
    }

    /// V2 with wrong spending key should fail verification.
    function testFuzz_verifyV2WrongKey(
        uint256 sk,
        uint256 wrongSk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) public view {
        sk = bound(sk, 1, FIELD - 2);
        wrongSk = bound(wrongSk, sk + 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainId = bound(chainId, 1, type(uint32).max);
        appId = bound(appId, 1, type(uint32).max);

        uint256 nullifier = harness.computeV2(sk, cm, chainId, appId);
        assertFalse(
            harness.verifyV2(nullifier, wrongSk, cm, chainId, appId),
            "verifyV2 should fail with wrong spending key"
        );
    }

    /// Same (sk, cm) but different chain IDs must produce different nullifiers.
    function testFuzz_crossChainDomainSeparation(
        uint256 sk,
        uint256 cm,
        uint256 chainA,
        uint256 chainB,
        uint256 appId
    ) public view {
        sk = bound(sk, 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainA = bound(chainA, 1, type(uint32).max - 1);
        chainB = bound(chainB, chainA + 1, type(uint32).max);
        appId = bound(appId, 1, type(uint32).max);

        uint256 nulA = harness.computeV2(sk, cm, chainA, appId);
        uint256 nulB = harness.computeV2(sk, cm, chainB, appId);
        assertTrue(
            nulA != nulB,
            "Same note on different chains must produce different nullifiers"
        );
    }

    /// Same (sk, cm, chainId) but different app IDs must produce different nullifiers.
    function testFuzz_appIdSeparation(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appA,
        uint256 appB
    ) public view {
        sk = bound(sk, 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainId = bound(chainId, 1, type(uint32).max);
        appA = bound(appA, 1, type(uint32).max - 1);
        appB = bound(appB, appA + 1, type(uint32).max);

        uint256 nulA = harness.computeV2(sk, cm, chainId, appA);
        uint256 nulB = harness.computeV2(sk, cm, chainId, appB);
        assertTrue(
            nulA != nulB,
            "Same note on different apps must produce different nullifiers"
        );
    }

    /// V1 and V2 must produce different nullifiers (except negligible collision).
    function testFuzz_v1v2Divergence(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) public view {
        sk = bound(sk, 1, FIELD - 1);
        cm = bound(cm, 1, FIELD - 1);
        chainId = bound(chainId, 1, type(uint32).max);
        appId = bound(appId, 1, type(uint32).max);

        uint256 nulV1 = harness.computeV1(sk, cm);
        uint256 nulV2 = harness.computeV2(sk, cm, chainId, appId);
        assertTrue(nulV1 != nulV2, "V1 and V2 must diverge");
    }

    /// V2 nullifier output must be within BN254 scalar field.
    function testFuzz_v2OutputInField(
        uint256 sk,
        uint256 cm,
        uint256 chainId,
        uint256 appId
    ) public view {
        sk = bound(sk, 0, FIELD - 1);
        cm = bound(cm, 0, FIELD - 1);
        chainId = bound(chainId, 0, FIELD - 1);
        appId = bound(appId, 0, FIELD - 1);

        uint256 result = harness.computeV2(sk, cm, chainId, appId);
        assertTrue(result < FIELD, "V2 nullifier exceeds field modulus");
    }

    /// Domain tag is deterministic and commutative behavior is tested.
    function testFuzz_domainTagNonCommutative(
        uint256 a,
        uint256 b
    ) public view {
        a = bound(a, 1, FIELD - 1);
        b = bound(b, 1, FIELD - 1);
        vm.assume(a != b);

        uint256 tag1 = harness.computeDomainTag(a, b);
        uint256 tag2 = harness.computeDomainTag(b, a);
        assertTrue(tag1 != tag2, "Domain tag should be non-commutative");
    }
}
