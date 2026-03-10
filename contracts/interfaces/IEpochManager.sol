// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEpochManager — Interface for epoch-based nullifier management
/// @notice Partitions nullifiers into time-bounded epochs for efficient cross-chain sync
interface IEpochManager {
    /// @notice Emitted when a new epoch is started
    event EpochStarted(uint256 indexed epochId, uint256 startTime);

    /// @notice Emitted when an epoch is finalized with its Merkle root
    event EpochFinalized(
        uint256 indexed epochId,
        bytes32 nullifierRoot,
        uint256 nullifierCount
    );

    /// @notice Emitted when a remote epoch root is received from another chain
    event RemoteEpochRootReceived(
        uint256 indexed sourceChainId,
        uint256 indexed epochId,
        bytes32 nullifierRoot
    );

    /// @notice Start a new epoch (callable by governance or automated keeper)
    function startNewEpoch() external;

    /// @notice Finalize the current epoch, computing its nullifier Merkle root
    function finalizeEpoch() external;

    /// @notice Register a nullifier in the current epoch
    function registerNullifier(bytes32 nullifier) external;

    /// @notice Receive and store an epoch root from a remote chain
    function receiveRemoteEpochRoot(
        uint256 sourceChainId,
        uint256 epochId,
        bytes32 nullifierRoot
    ) external;

    /// @notice Check if a nullifier exists in any epoch (local or remote)
    function isNullifierSpentGlobal(
        bytes32 nullifier
    ) external view returns (bool);

    /// @notice Get the finalized root for a given epoch
    function getEpochRoot(uint256 epochId) external view returns (bytes32);

    /// @notice Get the current epoch ID
    function getCurrentEpochId() external view returns (uint256);
}
