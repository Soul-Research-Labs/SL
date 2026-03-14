// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPrivacyPool — Interface for the core privacy pool contract
/// @notice Manages shielded deposits, private transfers, and withdrawals
///         using ZK proofs. Chain-agnostic design — deployed on all target chains.
interface IPrivacyPool {
    /// @notice Emitted when assets are deposited (shielded) into the pool
    event Deposit(
        bytes32 indexed commitment,
        uint256 leafIndex,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when a private transfer occurs within the pool
    event Transfer(
        bytes32 indexed nullifier1,
        bytes32 indexed nullifier2,
        bytes32 outputCommitment1,
        bytes32 outputCommitment2,
        bytes32 newRoot
    );

    /// @notice Emitted when assets are withdrawn (unshielded) from the pool
    event Withdrawal(
        bytes32 indexed nullifier1,
        bytes32 indexed nullifier2,
        address indexed recipient,
        uint256 amount,
        bytes32 newRoot
    );

    /// @notice Emitted when an epoch's nullifier root is finalized
    event EpochFinalized(uint256 indexed epochId, bytes32 nullifierRoot);

    /// @notice Emitted when a commit-reveal deposit commit is submitted
    event DepositCommitted(
        bytes32 indexed commitHash,
        address indexed depositor,
        uint256 value
    );

    /// @notice Emitted when a commit-reveal deposit is revealed
    event DepositRevealed(bytes32 indexed commitment, uint256 value);

    /// @notice Emitted when an expired commit is reclaimed
    event CommitReclaimed(
        bytes32 indexed commitHash,
        address indexed depositor,
        uint256 value
    );

    /// @notice Submit the first phase of a commit-reveal deposit
    /// @param commitHash keccak256(abi.encodePacked(commitment, salt))
    function commitDeposit(bytes32 commitHash) external payable;

    /// @notice Reveal a previously committed deposit
    /// @param commitment The actual Poseidon commitment
    /// @param salt The salt used when committing
    function revealDeposit(bytes32 commitment, bytes32 salt) external;

    /// @notice Reclaim funds from an expired commit
    /// @param commitHash The commit hash to reclaim
    function reclaimExpiredCommit(bytes32 commitHash) external;

    /// @notice Deposit assets into the privacy pool
    /// @param commitment The Poseidon commitment for the deposited note
    /// @param amount The amount of native tokens to shield
    function deposit(bytes32 commitment, uint256 amount) external payable;

    /// @notice Execute a private transfer within the pool
    /// @param proof The ZK proof bytes
    /// @param merkleRoot The Merkle root the proof was generated against
    /// @param nullifiers The nullifiers being spent (length 2)
    /// @param outputCommitments The new output commitments (length 2)
    /// @param domainChainId Chain ID for domain-separated nullifiers (V2)
    /// @param domainAppId Application ID for domain separation
    function transfer(
        bytes calldata proof,
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        uint256 domainChainId,
        uint256 domainAppId
    ) external;

    /// @notice Withdraw (unshield) assets from the pool
    /// @param proof The ZK proof bytes
    /// @param merkleRoot The Merkle root the proof was generated against
    /// @param nullifiers The nullifiers being spent (length 2)
    /// @param outputCommitments Change output commitments (length 2)
    /// @param recipient The address to receive withdrawn funds
    /// @param exitValue The amount to withdraw
    function withdraw(
        bytes calldata proof,
        bytes32 merkleRoot,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputCommitments,
        address payable recipient,
        uint256 exitValue
    ) external;

    /// @notice Get the current Merkle root
    function getLatestRoot() external view returns (bytes32);

    /// @notice Check if a Merkle root is known (current or historical)
    function isKnownRoot(bytes32 root) external view returns (bool);

    /// @notice Check if a nullifier has been spent
    function isSpent(bytes32 nullifier) external view returns (bool);

    /// @notice Get the current leaf count (next insertion index)
    function getNextLeafIndex() external view returns (uint256);

    /// @notice Get the total pool balance
    function getPoolBalance() external view returns (uint256);
}
