// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @title TeleporterAdapter — Bridge adapter using Avalanche Teleporter
/// @notice Higher-level abstraction over AWM for cross-subnet messaging.
///         Teleporter provides reliable delivery, replay protection, and
///         receipt tracking built on top of raw AWM.
/// @dev See: https://github.com/ava-labs/teleporter
contract TeleporterAdapter is IBridgeAdapter {
    // ── Types ──────────────────────────────────────────────────────────

    /// @notice Teleporter message format
    struct TeleporterMessageInput {
        bytes32 destinationBlockchainID;
        address destinationAddress;
        TeleporterFeeInfo feeInfo;
        uint256 requiredGasLimit;
        address[] allowedRelayerAddresses;
        bytes message;
    }

    struct TeleporterFeeInfo {
        address feeTokenAddress;
        uint256 amount;
    }

    // ── Interfaces ─────────────────────────────────────────────────────

    /// @notice Teleporter messenger interface (deployed by Avalanche on each subnet)
    interface ITeleporterMessenger {
        function sendCrossChainMessage(TeleporterMessageInput calldata messageInput)
            external
            returns (bytes32 messageID);

        function getMessageHash(bytes32 sourceBlockchainID, uint256 messageNonce)
            external
            view
            returns (bytes32);
    }

    /// @notice Teleporter receiver interface
    interface ITeleporterReceiver {
        function receiveTeleporterMessage(
            bytes32 sourceBlockchainID,
            address originSenderAddress,
            bytes calldata message
        ) external;
    }

    // ── State ──────────────────────────────────────────────────────────

    ITeleporterMessenger public immutable teleporterMessenger;
    bytes32 public immutable sourceBlockchainID;

    /// @notice Chain ID → Avalanche blockchain ID mapping
    mapping(uint256 => bytes32) public chainToBlockchainID;

    /// @notice Blockchain ID → receiving contract mapping
    mapping(bytes32 => address) public remoteReceivers;

    /// @notice Authorized Teleporter messenger addresses (for upgrades)
    mapping(address => bool) public authorizedMessengers;

    /// @notice Processed messages for deduplication
    mapping(bytes32 => bool) public processedMessages;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error UnsupportedChain(uint256 chainId);
    error InvalidTeleporterMessenger();
    error MessageAlreadyProcessed(bytes32 messageId);

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    modifier onlyTeleporter() {
        if (!authorizedMessengers[msg.sender]) revert InvalidTeleporterMessenger();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(address _teleporterMessenger, bytes32 _sourceBlockchainID) {
        teleporterMessenger = ITeleporterMessenger(_teleporterMessenger);
        sourceBlockchainID = _sourceBlockchainID;
        governance = msg.sender;
        authorizedMessengers[_teleporterMessenger] = true;
    }

    // ── IBridgeAdapter ─────────────────────────────────────────────────

    /// @inheritdoc IBridgeAdapter
    function sendMessage(
        uint256 destinationChainId,
        address recipient,
        bytes calldata payload,
        uint256 gasLimit
    ) external payable returns (bytes32 messageId) {
        bytes32 destBlockchainID = chainToBlockchainID[destinationChainId];
        if (destBlockchainID == bytes32(0)) revert UnsupportedChain(destinationChainId);

        // Build Teleporter message
        TeleporterMessageInput memory input = TeleporterMessageInput({
            destinationBlockchainID: destBlockchainID,
            destinationAddress: recipient,
            feeInfo: TeleporterFeeInfo({
                feeTokenAddress: address(0), // Native token fee
                amount: 0 // Relayer incentive (can be set by governance)
            }),
            requiredGasLimit: gasLimit,
            allowedRelayerAddresses: new address[](0), // Any relayer can deliver
            message: abi.encode(msg.sender, payload)
        });

        messageId = teleporterMessenger.sendCrossChainMessage(input);

        emit MessageSent(destinationChainId, messageId, msg.sender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function receiveMessage(
        uint256 sourceChainId,
        address sender,
        bytes calldata payload
    ) external onlyTeleporter {
        bytes32 messageId = keccak256(abi.encodePacked(
            sourceChainId,
            sender,
            block.number,
            payload
        ));

        if (processedMessages[messageId]) revert MessageAlreadyProcessed(messageId);
        processedMessages[messageId] = true;

        emit MessageReceived(sourceChainId, messageId, sender, payload);
    }

    /// @notice Called by Teleporter messenger when a message arrives
    /// @dev Implements ITeleporterReceiver
    function receiveTeleporterMessage(
        bytes32 _sourceBlockchainID,
        address originSenderAddress,
        bytes calldata message
    ) external onlyTeleporter {
        (address originalSender, bytes memory payload) = abi.decode(message, (address, bytes));

        // Find the chain ID for this blockchain ID
        // In production, maintain a reverse mapping; here we pass 0 and let the
        // event consumer resolve it
        bytes32 messageId = keccak256(abi.encodePacked(
            _sourceBlockchainID,
            originSenderAddress,
            block.number,
            payload
        ));

        if (processedMessages[messageId]) revert MessageAlreadyProcessed(messageId);
        processedMessages[messageId] = true;

        emit MessageReceived(0, messageId, originalSender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function estimateFee(
        uint256, /* destinationChainId */
        bytes calldata, /* payload */
        uint256 /* gasLimit */
    ) external pure returns (uint256 fee) {
        // Teleporter fee is the relayer incentive — currently 0 for permissionless relay
        return 0;
    }

    /// @inheritdoc IBridgeAdapter
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return chainToBlockchainID[chainId] != bytes32(0);
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProtocol() external pure returns (string memory) {
        return "Teleporter";
    }

    // ── Governance ─────────────────────────────────────────────────────

    function registerChain(
        uint256 chainId,
        bytes32 blockchainID,
        address receiver
    ) external onlyGovernance {
        chainToBlockchainID[chainId] = blockchainID;
        remoteReceivers[blockchainID] = receiver;
    }

    function authorizeMessenger(address messenger) external onlyGovernance {
        authorizedMessengers[messenger] = true;
    }

    function revokeMessenger(address messenger) external onlyGovernance {
        authorizedMessengers[messenger] = false;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }
}
