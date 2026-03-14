// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoseidonHasher} from "../libraries/PoseidonHasher.sol";

/// @title UniversalNullifierRegistry — Cross-chain nullifier deduplication
/// @notice Aggregates epoch nullifier roots from all deployed chains into a
///         single registry. Enables any chain to verify that a nullifier has
///         not been spent on ANY other chain in the network.
///
/// @dev Epoch roots are published by each chain's EpochManager (via bridge
///      adapters) after epoch finalization. This contract maintains:
///      1. Per-chain epoch root history
///      2. A global aggregated root combining all chains' latest epoch roots
///      3. Cross-chain nullifier inclusion proof verification
///
/// Deployed on a hub chain (e.g., Avalanche C-Chain or Ethereum) and replicated
/// to all other chains via their respective bridge adapters.
contract UniversalNullifierRegistry {
    // ── Types ──────────────────────────────────────────────────────────

    struct ChainRegistration {
        uint256 chainId;
        string name;
        address bridgeAdapter; // authorized submitter
        uint256 latestEpochId;
        bytes32 latestEpochRoot;
        uint256 lastUpdatedAt;
        bool active;
    }

    struct GlobalEpochSnapshot {
        uint256 snapshotId;
        bytes32 aggregatedRoot; // Poseidon tree of all chain epoch roots
        uint256 timestamp;
        uint256 chainCount;
    }

    // ── State ──────────────────────────────────────────────────────────

    /// @notice Governance address
    address public governance;

    /// @notice Registered chains: chainId → registration
    mapping(uint256 => ChainRegistration) public chains;

    /// @notice List of registered chain IDs (for iteration)
    uint256[] public registeredChainIds;

    /// @notice Per-chain epoch root history: chainId → epochId → nullifierRoot
    mapping(uint256 => mapping(uint256 => bytes32)) public epochRoots;

    /// @notice Global snapshots — aggregated root from all chains
    GlobalEpochSnapshot[] public snapshots;

    /// @notice Latest global aggregated root
    bytes32 public globalRoot;

    /// @notice Whether a nullifier has been reported spent (via proof)
    /// chainId → nullifier → spent
    mapping(uint256 => mapping(bytes32 => bool)) public nullifierSpentGlobal;

    // ── Events ─────────────────────────────────────────────────────────

    event ChainRegistered(
        uint256 indexed chainId,
        string name,
        address bridgeAdapter
    );
    event ChainDeactivated(uint256 indexed chainId);
    event EpochRootReceived(
        uint256 indexed chainId,
        uint256 indexed epochId,
        bytes32 nullifierRoot,
        uint256 nullifierCount
    );
    event GlobalSnapshotCreated(
        uint256 indexed snapshotId,
        bytes32 aggregatedRoot,
        uint256 chainCount
    );
    event NullifierReportedSpent(
        uint256 indexed chainId,
        bytes32 indexed nullifier
    );

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error ChainNotRegistered(uint256 chainId);
    error ChainAlreadyRegistered(uint256 chainId);
    error ChainInactive(uint256 chainId);
    error EpochAlreadyRecorded(uint256 chainId, uint256 epochId);
    error InvalidEpochSequence(
        uint256 chainId,
        uint256 expected,
        uint256 received
    );
    error NullifierAlreadyReported(uint256 chainId, bytes32 nullifier);
    error InvalidInclusionProof();

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyAuthorizedBridge(uint256 chainId) {
        ChainRegistration storage reg = chains[chainId];
        if (!reg.active) revert ChainInactive(chainId);
        if (msg.sender != reg.bridgeAdapter && msg.sender != governance) {
            revert Unauthorized();
        }
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(address _governance) {
        governance = _governance;
    }

    // ── Chain Registration ─────────────────────────────────────────────

    /// @notice Register a new chain in the universal registry
    /// @param chainId The chain's unique identifier
    /// @param name Human-readable chain name
    /// @param bridgeAdapter Address authorized to submit epoch roots for this chain
    function registerChain(
        uint256 chainId,
        string calldata name,
        address bridgeAdapter
    ) external onlyGovernance {
        if (chains[chainId].active) revert ChainAlreadyRegistered(chainId);

        chains[chainId] = ChainRegistration({
            chainId: chainId,
            name: name,
            bridgeAdapter: bridgeAdapter,
            latestEpochId: 0,
            latestEpochRoot: bytes32(0),
            lastUpdatedAt: block.timestamp,
            active: true
        });

        registeredChainIds.push(chainId);

        emit ChainRegistered(chainId, name, bridgeAdapter);
    }

    /// @notice Deactivate a chain (keeping history intact)
    function deactivateChain(uint256 chainId) external onlyGovernance {
        if (!chains[chainId].active) revert ChainInactive(chainId);
        chains[chainId].active = false;
        emit ChainDeactivated(chainId);
    }

    /// @notice Update the bridge adapter authorized for a chain
    function updateBridgeAdapter(
        uint256 chainId,
        address newAdapter
    ) external onlyGovernance {
        if (chains[chainId].chainId == 0) revert ChainNotRegistered(chainId);
        chains[chainId].bridgeAdapter = newAdapter;
    }

    // ── Epoch Root Submission ──────────────────────────────────────────

    /// @notice Submit an epoch nullifier root from a specific chain
    /// @dev Called by the chain's authorized bridge adapter after epoch finalization
    /// @param chainId Source chain ID
    /// @param epochId Epoch ID on that chain
    /// @param nullifierRoot Merkle root of all nullifiers in that epoch
    /// @param nullifierCount Number of nullifiers in the epoch
    function submitEpochRoot(
        uint256 chainId,
        uint256 epochId,
        bytes32 nullifierRoot,
        uint256 nullifierCount
    ) external onlyAuthorizedBridge(chainId) {
        // Ensure sequential epoch submission (first epoch must be 0)
        ChainRegistration storage reg = chains[chainId];
        if (reg.latestEpochRoot == bytes32(0) && reg.latestEpochId == 0) {
            // First ever submission for this chain — must start at epoch 0
            if (epochId != 0) {
                revert InvalidEpochSequence(chainId, 0, epochId);
            }
        } else {
            if (epochId != reg.latestEpochId + 1) {
                revert InvalidEpochSequence(
                    chainId,
                    reg.latestEpochId + 1,
                    epochId
                );
            }
        }
        if (epochRoots[chainId][epochId] != bytes32(0)) {
            revert EpochAlreadyRecorded(chainId, epochId);
        }

        // Store the epoch root
        epochRoots[chainId][epochId] = nullifierRoot;
        reg.latestEpochId = epochId;
        reg.latestEpochRoot = nullifierRoot;
        reg.lastUpdatedAt = block.timestamp;

        emit EpochRootReceived(chainId, epochId, nullifierRoot, nullifierCount);
    }

    // ── Global Snapshot ────────────────────────────────────────────────

    /// @notice Create a global snapshot aggregating the latest epoch roots
    ///         from all active chains into a single Poseidon Merkle root.
    /// @dev Anyone can trigger this — it's a permissionless aggregation.
    function createGlobalSnapshot() external returns (uint256 snapshotId) {
        // Collect latest roots from all active chains
        uint256 activeCount = 0;
        bytes32 aggregated = bytes32(0);

        for (uint256 i = 0; i < registeredChainIds.length; i++) {
            uint256 cid = registeredChainIds[i];
            if (
                chains[cid].active && chains[cid].latestEpochRoot != bytes32(0)
            ) {
                aggregated = bytes32(
                    PoseidonHasher.hash(
                        uint256(aggregated),
                        uint256(chains[cid].latestEpochRoot)
                    )
                );
                activeCount++;
            }
        }

        snapshotId = snapshots.length;
        snapshots.push(
            GlobalEpochSnapshot({
                snapshotId: snapshotId,
                aggregatedRoot: aggregated,
                timestamp: block.timestamp,
                chainCount: activeCount
            })
        );

        globalRoot = aggregated;

        emit GlobalSnapshotCreated(snapshotId, aggregated, activeCount);
    }

    // ── Cross-Chain Nullifier Verification ─────────────────────────────

    /// @notice Report a nullifier as spent on a specific chain with an
    ///         inclusion proof against that chain's epoch root.
    /// @param chainId The chain where the nullifier was spent
    /// @param nullifier The nullifier hash
    /// @param epochId The epoch in which the nullifier was spent
    /// @param proof Merkle inclusion proof (sibling hashes)
    /// @param pathIndices Path indices (0 = left, 1 = right)
    function reportNullifierSpent(
        uint256 chainId,
        bytes32 nullifier,
        uint256 epochId,
        bytes32[] calldata proof,
        uint256[] calldata pathIndices
    ) external {
        // Verify report chain is registered
        if (chains[chainId].chainId == 0) revert ChainNotRegistered(chainId);

        // Verify nullifier isn't already reported
        if (nullifierSpentGlobal[chainId][nullifier]) {
            revert NullifierAlreadyReported(chainId, nullifier);
        }

        // Get the epoch root for verification
        bytes32 epochRoot = epochRoots[chainId][epochId];
        if (epochRoot == bytes32(0)) revert InvalidInclusionProof();

        // Verify Merkle inclusion proof
        if (!_verifyInclusion(nullifier, epochRoot, proof, pathIndices)) {
            revert InvalidInclusionProof();
        }

        // Mark as globally spent
        nullifierSpentGlobal[chainId][nullifier] = true;

        emit NullifierReportedSpent(chainId, nullifier);
    }

    /// @notice Check if a nullifier is spent on ANY registered chain
    /// @param nullifier The nullifier hash to check
    /// @return spent True if the nullifier is reported spent on any chain
    /// @return spentOnChainId The chain ID where it was spent (0 if not spent)
    function isNullifierSpentGlobally(
        bytes32 nullifier
    ) external view returns (bool spent, uint256 spentOnChainId) {
        for (uint256 i = 0; i < registeredChainIds.length; i++) {
            uint256 cid = registeredChainIds[i];
            if (nullifierSpentGlobal[cid][nullifier]) {
                return (true, cid);
            }
        }
        return (false, 0);
    }

    // ── View Functions ─────────────────────────────────────────────────

    /// @notice Get the number of registered chains
    function getRegisteredChainCount() external view returns (uint256) {
        return registeredChainIds.length;
    }

    /// @notice Get the latest epoch info for a specific chain
    function getChainLatestEpoch(
        uint256 chainId
    ) external view returns (uint256 epochId, bytes32 root) {
        ChainRegistration storage reg = chains[chainId];
        return (reg.latestEpochId, reg.latestEpochRoot);
    }

    /// @notice Get a specific global snapshot
    function getSnapshot(
        uint256 snapshotId
    ) external view returns (GlobalEpochSnapshot memory) {
        return snapshots[snapshotId];
    }

    /// @notice Get the total number of global snapshots created
    function getSnapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    /// @dev Maximum depth for Merkle inclusion proofs (matching tree depth)
    uint256 public constant MAX_PROOF_DEPTH = 32;

    // ── Internal ───────────────────────────────────────────────────────

    /// @dev Verify a Merkle inclusion proof against a root
    function _verifyInclusion(
        bytes32 leaf,
        bytes32 root,
        bytes32[] calldata proof,
        uint256[] calldata pathIndices
    ) internal pure returns (bool) {
        if (proof.length != pathIndices.length) return false;
        if (proof.length == 0) return false;
        if (proof.length > MAX_PROOF_DEPTH) return false;

        bytes32 current = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            if (pathIndices[i] > 1) return false; // must be 0 or 1
            if (pathIndices[i] == 0) {
                current = bytes32(
                    PoseidonHasher.hash(uint256(current), uint256(proof[i]))
                );
            } else {
                current = bytes32(
                    PoseidonHasher.hash(uint256(proof[i]), uint256(current))
                );
            }
        }
        return current == root;
    }
}
