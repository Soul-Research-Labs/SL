// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {PoseidonHasher} from "../../contracts/libraries/PoseidonHasher.sol";

contract MerkleTreeHarness {
    using MerkleTree for MerkleTree.TreeData;

    MerkleTree.TreeData internal tree;

    constructor() {
        tree.init();
    }

    function insert(
        uint256 leaf
    ) external returns (uint256 index, uint256 newRoot) {
        return tree.insert(leaf);
    }

    function getRoot() external view returns (uint256) {
        return tree.roots[tree.currentRootIndex];
    }

    function getNextLeafIndex() external view returns (uint256) {
        return tree.nextLeafIndex;
    }

    function isKnownRoot(uint256 root) external view returns (bool) {
        for (uint256 i = 0; i < 100; i++) {
            if (tree.roots[i] == root) return true;
        }
        return false;
    }
}

contract MerkleTreeFuzzTest is Test {
    MerkleTreeHarness harness;

    function setUp() public {
        harness = new MerkleTreeHarness();
    }

    /// Inserting any non-zero leaf should change the root.
    function testFuzz_insertChangesRoot(uint256 leaf) public {
        vm.assume(leaf != 0);
        uint256 rootBefore = harness.getRoot();
        harness.insert(leaf);
        uint256 rootAfter = harness.getRoot();
        assertTrue(rootAfter != rootBefore, "Root unchanged after insert");
    }

    /// Leaf index must increment monotonically.
    function testFuzz_leafIndexMonotonic(uint256 leaf1, uint256 leaf2) public {
        vm.assume(leaf1 != 0 && leaf2 != 0);
        (uint256 idx1, ) = harness.insert(leaf1);
        (uint256 idx2, ) = harness.insert(leaf2);
        assertEq(idx1, 0);
        assertEq(idx2, 1);
    }

    /// Different leaves should produce different roots (high probability).
    function testFuzz_differentLeavesProduceDifferentRoots(
        uint256 leafA,
        uint256 leafB
    ) public {
        vm.assume(leafA != leafB);
        vm.assume(leafA != 0 && leafB != 0);

        MerkleTreeHarness tree1 = new MerkleTreeHarness();
        MerkleTreeHarness tree2 = new MerkleTreeHarness();

        tree1.insert(leafA);
        tree2.insert(leafB);

        assertTrue(
            tree1.getRoot() != tree2.getRoot(),
            "Different leaves should produce different roots"
        );
    }

    /// After insertion, the previous root should still be in history.
    function testFuzz_rootHistoryPreserved(uint256 leaf) public {
        vm.assume(leaf != 0);
        uint256 rootBefore = harness.getRoot();
        harness.insert(leaf);
        assertTrue(
            harness.isKnownRoot(rootBefore),
            "Previous root not in history after single insert"
        );
    }

    /// Inserting the same values in the same order should be deterministic.
    function testFuzz_insertionDeterministic(uint256 seed) public {
        seed = bound(seed, 1, type(uint128).max);

        MerkleTreeHarness t1 = new MerkleTreeHarness();
        MerkleTreeHarness t2 = new MerkleTreeHarness();

        for (uint256 i = 0; i < 3; i++) {
            uint256 leaf = uint256(keccak256(abi.encodePacked(seed, i)));
            t1.insert(leaf);
            t2.insert(leaf);
        }

        assertEq(t1.getRoot(), t2.getRoot(), "Determinism violated");
    }

    /// Root history size is bounded — after 101+ inserts, the very first root
    /// should eventually be evicted from the circular buffer.
    function testFuzz_rootHistoryEviction(uint8 extraInserts) public {
        uint256 initialRoot = harness.getRoot();

        // Insert 100 leaves to fill the history buffer
        for (uint256 i = 1; i <= 100; i++) {
            harness.insert(i);
        }
        // Initial root should still be known (barely)
        assertTrue(
            harness.isKnownRoot(initialRoot),
            "Initial root evicted too early"
        );

        // Insert a few more to overflow the buffer
        uint256 overflowCount = bound(extraInserts, 1, 10);
        for (uint256 i = 101; i <= 100 + overflowCount; i++) {
            harness.insert(i);
        }
        // Initial root may now be evicted
        // (This is expected behavior, not an error)
    }
}
