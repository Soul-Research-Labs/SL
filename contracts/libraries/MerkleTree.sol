// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoseidonHasher} from "./PoseidonHasher.sol";

/// @title MerkleTree — Append-only incremental Merkle tree (depth 32)
/// @notice Stores note commitments. Uses Poseidon hash for ZK-friendliness.
///         Maintains a history of recent roots for proof validation against
///         slightly stale states.
library MerkleTree {
    using PoseidonHasher for uint256;

    uint256 internal constant DEPTH = 32;
    uint256 internal constant ROOT_HISTORY_SIZE = 100;

    struct TreeData {
        uint256 nextLeafIndex;
        // Current subtree hashes at each level (for incremental insertion)
        uint256[DEPTH] filledSubtrees;
        // Circular buffer of historical roots
        uint256[ROOT_HISTORY_SIZE] roots;
        uint256 currentRootIndex;
    }

    /// @notice Initialize the tree with zero-value subtrees
    function init(TreeData storage self) internal {
        // Precompute zero hashes for empty subtrees
        uint256 currentZero = 0;
        for (uint256 i = 0; i < DEPTH; i++) {
            self.filledSubtrees[i] = currentZero;
            currentZero = PoseidonHasher.hash(currentZero, currentZero);
        }
        self.roots[0] = currentZero;
    }

    /// @notice Insert a leaf into the tree
    /// @param self The tree storage
    /// @param leaf The leaf value (note commitment)
    /// @return index The leaf index
    /// @return newRoot The new Merkle root
    function insert(
        TreeData storage self,
        uint256 leaf
    ) internal returns (uint256 index, uint256 newRoot) {
        uint256 _nextIndex = self.nextLeafIndex;
        require(_nextIndex < 2 ** DEPTH, "MerkleTree: tree full");

        uint256 currentIndex = _nextIndex;
        uint256 currentHash = leaf;
        uint256 left;
        uint256 right;

        for (uint256 i = 0; i < DEPTH; i++) {
            if (currentIndex % 2 == 0) {
                left = currentHash;
                right = _zeros(i);
                self.filledSubtrees[i] = currentHash;
            } else {
                left = self.filledSubtrees[i];
                right = currentHash;
            }

            currentHash = PoseidonHasher.hash(left, right);
            currentIndex /= 2;
        }

        uint256 newRootIndex = (self.currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        self.roots[newRootIndex] = currentHash;
        self.currentRootIndex = newRootIndex;
        self.nextLeafIndex = _nextIndex + 1;

        return (_nextIndex, currentHash);
    }

    /// @notice Check if a root is in the history
    function isKnownRoot(
        TreeData storage self,
        uint256 root
    ) internal view returns (bool) {
        if (root == 0) return false;
        uint256 idx = self.currentRootIndex;
        for (uint256 i = 0; i < ROOT_HISTORY_SIZE; i++) {
            if (self.roots[idx] == root) return true;
            if (idx == 0) idx = ROOT_HISTORY_SIZE - 1;
            else idx--;
        }
        return false;
    }

    /// @notice Get the latest root
    function getLatestRoot(
        TreeData storage self
    ) internal view returns (uint256) {
        return self.roots[self.currentRootIndex];
    }

    /// @dev Precomputed zero values at each level
    function _zeros(uint256 level) private pure returns (uint256) {
        if (level == 0) return 0;
        // Each zero[i] = Poseidon(zero[i-1], zero[i-1])
        // For production, these should be precomputed constants
        uint256 z = 0;
        for (uint256 i = 0; i < level; i++) {
            z = PoseidonHasher.hash(z, z);
        }
        return z;
    }
}
