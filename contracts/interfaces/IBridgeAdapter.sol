// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IBridgeAdapter — Unified interface for cross-chain bridge adapters
/// @notice Each target chain implements this interface to relay ZK proof envelopes
///         and nullifier roots across chain boundaries.
interface IBridgeAdapter {
    /// @notice Emitted when a message is sent cross-chain
    event MessageSent(
        uint256 indexed destinationChainId,
        bytes32 indexed messageId,
        address sender,
        bytes payload
    );

    /// @notice Emitted when a message is received from another chain
    event MessageReceived(
        uint256 indexed sourceChainId,
        bytes32 indexed messageId,
        address sender,
        bytes payload
    );

    /// @notice Send a proof envelope or nullifier root to a destination chain
    /// @param destinationChainId The target chain's domain/chain ID
    /// @param recipient The receiving contract on the destination chain
    /// @param payload ABI-encoded proof envelope or epoch root data
    /// @param gasLimit Gas limit for execution on the destination chain
    /// @return messageId Unique identifier for tracking the cross-chain message
    function sendMessage(
        uint256 destinationChainId,
        address recipient,
        bytes calldata payload,
        uint256 gasLimit
    ) external payable returns (bytes32 messageId);

    /// @notice Receive and process a cross-chain message
    /// @param sourceChainId The originating chain's domain/chain ID
    /// @param sender The sending contract on the source chain
    /// @param payload ABI-encoded proof envelope or epoch root data
    function receiveMessage(
        uint256 sourceChainId,
        address sender,
        bytes calldata payload
    ) external;

    /// @notice Estimate the fee required to send a cross-chain message
    /// @param destinationChainId The target chain's domain/chain ID
    /// @param payload The message payload
    /// @param gasLimit Gas limit for destination execution
    /// @return fee The estimated fee in native tokens
    function estimateFee(
        uint256 destinationChainId,
        bytes calldata payload,
        uint256 gasLimit
    ) external view returns (uint256 fee);

    /// @notice Check if a destination chain is supported by this adapter
    /// @param chainId The chain ID to check
    /// @return supported Whether the chain is supported
    function isChainSupported(
        uint256 chainId
    ) external view returns (bool supported);

    /// @notice Get the adapter's bridge protocol identifier
    /// @return protocol Human-readable protocol name (e.g., "AWM", "XCM", "IBC")
    function bridgeProtocol() external pure returns (string memory protocol);
}
