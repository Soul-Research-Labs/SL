// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEpochManager} from "../interfaces/IEpochManager.sol";
import {PoseidonHasher} from "../libraries/PoseidonHasher.sol";

/// @title EpochManager — Epoch-based nullifier partitioning for cross-chain sync
/// @notice Partitions nullifiers into time-bounded epochs. Each epoch is finalized
///         with a Merkle root of its nullifiers, which can then be synced to other
///         chains via bridge adapters. This enables global double-spend prevention.
contract EpochManager is IEpochManager {
    // ── Types ──────────────────────────────────────────────────────────

    struct Epoch {
        uint256 startTime;
        uint256 endTime;
        bytes32 nullifierRoot;
        uint256 nullifierCount;
        bool finalized;
    }

    struct RemoteRoot {
        uint256 sourceChainId;
        uint256 epochId;
        bytes32 nullifierRoot;
        uint256 receivedAt;
    }

    // ── State ──────────────────────────────────────────────────────────

    uint256 public currentEpochId;
    uint256 public immutable epochDuration;
    uint256 public immutable domainChainId;

    mapping(uint256 => Epoch) public epochs;
    mapping(uint256 => bytes32[]) private _epochNullifiers;

    /// @notice Remote epoch roots received from other chains
    /// key: keccak256(sourceChainId, epochId)
    mapping(bytes32 => RemoteRoot) public remoteRoots;

    /// @notice Global nullifier lookup (all local nullifiers)
    mapping(bytes32 => bool) public localNullifiers;

    /// @notice Authorized privacy pools that can register nullifiers
    mapping(address => bool) public authorizedPools;

    /// @notice Authorized bridge adapters that can submit remote roots
    mapping(address => bool) public authorizedBridges;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error EpochAlreadyFinalized();
    error EpochNotReady();
    error InvalidRemoteRoot();

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyAuthorizedBridge() {
        if (!authorizedBridges[msg.sender]) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(uint256 _epochDuration, uint256 _domainChainId) {
        epochDuration = _epochDuration;
        domainChainId = _domainChainId;
        governance = msg.sender;

        // Initialize first epoch
        epochs[0] = Epoch({
            startTime: block.timestamp,
            endTime: block.timestamp + _epochDuration,
            nullifierRoot: bytes32(0),
            nullifierCount: 0,
            finalized: false
        });

        emit EpochStarted(0, block.timestamp);
    }

    // ── Epoch Lifecycle ────────────────────────────────────────────────

    /// @inheritdoc IEpochManager
    function startNewEpoch() external {
        Epoch storage current = epochs[currentEpochId];
        if (block.timestamp < current.endTime) revert EpochNotReady();
        if (!current.finalized) {
            _finalizeEpochInternal(currentEpochId);
        }

        currentEpochId++;
        epochs[currentEpochId] = Epoch({
            startTime: block.timestamp,
            endTime: block.timestamp + epochDuration,
            nullifierRoot: bytes32(0),
            nullifierCount: 0,
            finalized: false
        });

        emit EpochStarted(currentEpochId, block.timestamp);
    }

    /// @inheritdoc IEpochManager
    function finalizeEpoch() external {
        _finalizeEpochInternal(currentEpochId);
    }

    /// @inheritdoc IEpochManager
    function registerNullifier(bytes32 nullifier) external onlyAuthorizedPool {
        localNullifiers[nullifier] = true;
        _epochNullifiers[currentEpochId].push(nullifier);
        epochs[currentEpochId].nullifierCount++;
    }

    // ── Cross-Chain Sync ───────────────────────────────────────────────

    /// @inheritdoc IEpochManager
    function receiveRemoteEpochRoot(
        uint256 sourceChainId,
        uint256 epochId,
        bytes32 nullifierRoot
    ) external onlyAuthorizedBridge {
        if (nullifierRoot == bytes32(0)) revert InvalidRemoteRoot();

        bytes32 key = keccak256(abi.encodePacked(sourceChainId, epochId));
        remoteRoots[key] = RemoteRoot({
            sourceChainId: sourceChainId,
            epochId: epochId,
            nullifierRoot: nullifierRoot,
            receivedAt: block.timestamp
        });

        emit RemoteEpochRootReceived(sourceChainId, epochId, nullifierRoot);
    }

    // ── View Functions ─────────────────────────────────────────────────

    /// @inheritdoc IEpochManager
    function isNullifierSpentGlobal(
        bytes32 nullifier
    ) external view returns (bool) {
        // First check local nullifiers
        return localNullifiers[nullifier];
        // Note: Checking remote nullifiers requires Merkle proof from the remote root
        // This is handled by the proof verification circuit (which checks nullifier
        // non-membership against remote epoch roots)
    }

    /// @inheritdoc IEpochManager
    function getEpochRoot(uint256 epochId) external view returns (bytes32) {
        return epochs[epochId].nullifierRoot;
    }

    /// @inheritdoc IEpochManager
    function getCurrentEpochId() external view returns (uint256) {
        return currentEpochId;
    }

    /// @notice Get a remote epoch root
    function getRemoteEpochRoot(
        uint256 sourceChainId,
        uint256 epochId
    ) external view returns (bytes32) {
        bytes32 key = keccak256(abi.encodePacked(sourceChainId, epochId));
        return remoteRoots[key].nullifierRoot;
    }

    /// @notice Get nullifier count for an epoch
    function getEpochNullifierCount(
        uint256 epochId
    ) external view returns (uint256) {
        return epochs[epochId].nullifierCount;
    }

    // ── Governance ─────────────────────────────────────────────────────

    function authorizePool(address pool) external onlyGovernance {
        authorizedPools[pool] = true;
    }

    function revokePool(address pool) external onlyGovernance {
        authorizedPools[pool] = false;
    }

    function authorizeBridge(address bridge) external onlyGovernance {
        authorizedBridges[bridge] = true;
    }

    function revokeBridge(address bridge) external onlyGovernance {
        authorizedBridges[bridge] = false;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    // ── Internal ───────────────────────────────────────────────────────

    function _finalizeEpochInternal(uint256 epochId) private {
        Epoch storage epoch = epochs[epochId];
        if (epoch.finalized) revert EpochAlreadyFinalized();

        // Compute Merkle root of all nullifiers in this epoch
        bytes32 root = _computeNullifierRoot(epochId);
        epoch.nullifierRoot = root;
        epoch.endTime = block.timestamp;
        epoch.finalized = true;

        emit EpochFinalized(epochId, root, epoch.nullifierCount);
    }

    function _computeNullifierRoot(
        uint256 epochId
    ) private view returns (bytes32) {
        bytes32[] storage nullifiers = _epochNullifiers[epochId];
        uint256 count = nullifiers.length;

        if (count == 0) return bytes32(0);
        if (count == 1) return nullifiers[0];

        // Build a proper binary Merkle tree (bottom-up).
        // Pad to next power of two so every level is balanced.
        uint256 n = _nextPowerOfTwo(count);
        bytes32[] memory layer = new bytes32[](n);

        // Copy leaves; pad remainder with zero
        for (uint256 i = 0; i < count; i++) {
            layer[i] = nullifiers[i];
        }

        // Reduce layer by layer until a single root remains
        while (n > 1) {
            uint256 half = n / 2;
            for (uint256 i = 0; i < half; i++) {
                layer[i] = bytes32(
                    PoseidonHasher.hash(
                        uint256(layer[2 * i]),
                        uint256(layer[2 * i + 1])
                    )
                );
            }
            n = half;
        }
        return layer[0];
    }

    /// @dev Returns the smallest power of 2 >= x (minimum 2).
    function _nextPowerOfTwo(uint256 x) private pure returns (uint256) {
        if (x <= 2) return 2;
        uint256 p = 1;
        while (p < x) {
            p <<= 1;
        }
        return p;
    }
}
