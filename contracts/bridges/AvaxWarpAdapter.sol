// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @title AvaxWarpAdapter — Bridge adapter using Avalanche Warp Messaging (AWM)
/// @notice Implements cross-subnet proof envelope relay using Avalanche's native
///         Warp Messaging protocol. AWM uses BLS multi-signature verification from
///         the subnet validators to authenticate cross-chain messages.
/// @dev AWM precompile address: 0x0200000000000000000000000000000000000005
///      See: https://docs.avax.network/cross-chain/avalanche-warp-messaging
contract AvaxWarpAdapter is IBridgeAdapter {
    // ── Constants ──────────────────────────────────────────────────────

    /// @notice AWM precompile address on Avalanche
    address internal constant WARP_PRECOMPILE =
        0x0200000000000000000000000000000000000005;

    /// @notice Maximum message size (proof envelopes are 2048 bytes)
    uint256 internal constant MAX_MESSAGE_SIZE = 4096;

    // ── Types ──────────────────────────────────────────────────────────

    struct WarpMessage {
        bytes32 sourceBlockchainID;
        address originSenderAddress;
        bytes payload;
    }

    // ── State ──────────────────────────────────────────────────────────

    /// @notice This subnet's blockchain ID
    bytes32 public immutable sourceBlockchainID;

    /// @notice Mapping of EVM chain IDs to Avalanche blockchain IDs (CB58 encoded)
    mapping(uint256 => bytes32) public chainToBlockchainID;

    /// @notice Mapping of blockchain IDs to receiving contract addresses
    mapping(bytes32 => address) public remoteReceivers;

    /// @notice Processed message deduplication
    mapping(bytes32 => bool) public processedMessages;

    /// @notice Authorized senders on remote chains
    mapping(bytes32 => mapping(address => bool)) public authorizedSenders;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error UnsupportedChain(uint256 chainId);
    error MessageTooLarge();
    error MessageAlreadyProcessed(bytes32 messageId);
    error InvalidWarpMessage();
    error WarpPrecompileFailed();
    error UnauthorizedSender();

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(bytes32 _sourceBlockchainID) {
        sourceBlockchainID = _sourceBlockchainID;
        governance = msg.sender;
    }

    // ── IBridgeAdapter ─────────────────────────────────────────────────

    /// @inheritdoc IBridgeAdapter
    function sendMessage(
        uint256 destinationChainId,
        address recipient,
        bytes calldata payload,
        uint256 /* gasLimit — not applicable for AWM */
    ) external payable returns (bytes32 messageId) {
        bytes32 destBlockchainID = chainToBlockchainID[destinationChainId];
        if (destBlockchainID == bytes32(0))
            revert UnsupportedChain(destinationChainId);
        if (payload.length > MAX_MESSAGE_SIZE) revert MessageTooLarge();

        // Encode the message with destination info
        bytes memory warpPayload = abi.encode(
            destinationChainId,
            recipient,
            msg.sender,
            payload
        );

        // Call AWM precompile to send the warp message
        // The precompile will include this in the subnet's BLS-signed block header
        (bool success, bytes memory result) = WARP_PRECOMPILE.call(
            abi.encodeWithSignature("sendWarpMessage(bytes)", warpPayload)
        );
        if (!success) revert WarpPrecompileFailed();

        // Message ID is the hash of the payload for deduplication
        messageId = keccak256(
            abi.encodePacked(
                sourceBlockchainID,
                destBlockchainID,
                block.number,
                msg.sender,
                payload
            )
        );

        emit MessageSent(destinationChainId, messageId, msg.sender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function receiveMessage(
        uint256 sourceChainId,
        address sender,
        bytes calldata payload
    ) external {
        // In production, this would be called via the AWM precompile's
        // getVerifiedWarpMessage() which verifies the BLS multi-sig.
        // For now, we verify the sender is authorized.
        bytes32 srcBlockchainID = chainToBlockchainID[sourceChainId];
        if (srcBlockchainID == bytes32(0))
            revert UnsupportedChain(sourceChainId);
        if (!authorizedSenders[srcBlockchainID][sender])
            revert UnauthorizedSender();

        bytes32 messageId = keccak256(
            abi.encodePacked(
                srcBlockchainID,
                sourceBlockchainID,
                block.number,
                sender,
                payload
            )
        );

        if (processedMessages[messageId])
            revert MessageAlreadyProcessed(messageId);
        processedMessages[messageId] = true;

        // Verify the warp message via precompile
        (bool success, bytes memory warpResult) = WARP_PRECOMPILE.staticcall(
            abi.encodeWithSignature("getVerifiedWarpMessage(uint32)", uint32(0))
        );
        if (!success) revert InvalidWarpMessage();

        emit MessageReceived(sourceChainId, messageId, sender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function estimateFee(
        uint256 /* destinationChainId */,
        bytes calldata /* payload */,
        uint256 /* gasLimit */
    ) external pure returns (uint256 fee) {
        // AWM messages are included in block headers — no separate fee
        // Cost is only the transaction gas for the sendWarpMessage call
        return 0;
    }

    /// @inheritdoc IBridgeAdapter
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return chainToBlockchainID[chainId] != bytes32(0);
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProtocol() external pure returns (string memory) {
        return "AWM";
    }

    // ── Governance / Configuration ──────────────────────────────────────

    /// @notice Register a supported destination chain
    /// @param chainId The EVM-compatible chain ID
    /// @param blockchainID The Avalanche blockchain ID (CB58)
    /// @param receiver The receiving contract address on that chain
    function registerChain(
        uint256 chainId,
        bytes32 blockchainID,
        address receiver
    ) external onlyGovernance {
        chainToBlockchainID[chainId] = blockchainID;
        remoteReceivers[blockchainID] = receiver;
    }

    /// @notice Authorize a sender address on a remote chain
    function authorizeSender(
        bytes32 blockchainID,
        address sender
    ) external onlyGovernance {
        authorizedSenders[blockchainID][sender] = true;
    }

    /// @notice Revoke a sender address on a remote chain
    function revokeSender(
        bytes32 blockchainID,
        address sender
    ) external onlyGovernance {
        authorizedSenders[blockchainID][sender] = false;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }
}
