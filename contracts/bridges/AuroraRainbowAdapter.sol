// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @title AuroraRainbowAdapter — Bridge adapter for Near/Aurora Rainbow Bridge
/// @notice Routes proof envelopes between Aurora (Near's EVM) and Near native,
///         as well as cross-chain to Ethereum via the Rainbow Bridge.
/// @dev Uses Aurora's built-in bridge precompiles for Near ↔ Aurora messaging.
contract AuroraRainbowAdapter is IBridgeAdapter {
    // ── Constants ──────────────────────────────────────────────────────

    /// @notice Aurora cross-contract call precompile
    address internal constant AURORA_CROSS_CONTRACT =
        0x516Cded1D16af10CAd47D6D49128E2eB7d27b372;

    // ── State ──────────────────────────────────────────────────────────

    /// @notice Chain ID → Near account mapping for routing
    mapping(uint256 => string) public chainToNearAccount;

    /// @notice Processed messages
    mapping(bytes32 => bool) public processedMessages;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error UnsupportedChain(uint256 chainId);
    error BridgeCallFailed();
    error MessageAlreadyProcessed(bytes32 messageId);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    constructor() {
        governance = msg.sender;
    }

    // ── IBridgeAdapter ─────────────────────────────────────────────────

    /// @inheritdoc IBridgeAdapter
    function sendMessage(
        uint256 destinationChainId,
        address /* recipient */,
        bytes calldata payload,
        uint256 gasLimit
    ) external payable returns (bytes32 messageId) {
        string memory nearAccount = chainToNearAccount[destinationChainId];
        if (bytes(nearAccount).length == 0)
            revert UnsupportedChain(destinationChainId);

        // Encode cross-contract call to Near
        bytes memory callData = abi.encodePacked(
            nearAccount,
            // Near function call: receive_privacy_message(source_chain, sender, payload)
            '{"source_chain":',
            _uintToString(block.chainid),
            ',"sender":"',
            _addressToString(msg.sender),
            '","payload":"',
            _bytesToHex(payload),
            '"}'
        );

        (bool success, ) = AURORA_CROSS_CONTRACT.call{gas: gasLimit}(callData);
        if (!success) revert BridgeCallFailed();

        messageId = keccak256(
            abi.encodePacked(
                block.chainid,
                destinationChainId,
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
        bytes32 messageId = keccak256(
            abi.encodePacked(sourceChainId, sender, block.number, payload)
        );
        if (processedMessages[messageId])
            revert MessageAlreadyProcessed(messageId);
        processedMessages[messageId] = true;

        emit MessageReceived(sourceChainId, messageId, sender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function estimateFee(
        uint256,
        bytes calldata,
        uint256
    ) external pure returns (uint256) {
        return 0; // Rainbow Bridge fees are handled at the protocol level
    }

    /// @inheritdoc IBridgeAdapter
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return bytes(chainToNearAccount[chainId]).length > 0;
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProtocol() external pure returns (string memory) {
        return "RainbowBridge";
    }

    // ── Governance ─────────────────────────────────────────────────────

    function registerChain(
        uint256 chainId,
        string calldata nearAccount
    ) external onlyGovernance {
        chainToNearAccount[chainId] = nearAccount;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    // ── Internal Helpers ───────────────────────────────────────────────

    function _uintToString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _addressToString(
        address addr
    ) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }

    function _bytesToHex(
        bytes memory data
    ) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(data.length * 2);
        for (uint256 i = 0; i < data.length; i++) {
            str[i * 2] = alphabet[uint8(data[i] >> 4)];
            str[i * 2 + 1] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(str);
    }
}
