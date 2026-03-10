// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @title IbcBridgeAdapter — Bridge adapter using Cosmos IBC protocol
/// @notice For deployment on Evmos and other Cosmos EVM chains. Routes proof
///         envelopes and epoch roots via IBC packets to CosmWasm-based privacy
///         pools on Cosmos chains (Osmosis, Injective, Sei, Neutron, etc.).
/// @dev Uses the IBC precompile available on Evmos for EVM → IBC messaging.
///      See: https://docs.evmos.org/develop/smart-contracts/evm-extensions/ibc
contract IbcBridgeAdapter is IBridgeAdapter {
    // ── Constants ──────────────────────────────────────────────────────

    /// @notice IBC precompile on Evmos
    address internal constant IBC_PRECOMPILE =
        0x0000000000000000000000000000000000000802;

    // ── Types ──────────────────────────────────────────────────────────

    struct IbcRoute {
        string portId;
        string channelId;
        uint64 timeoutHeight;
        uint64 timeoutTimestamp;
        bool active;
    }

    // ── State ──────────────────────────────────────────────────────────

    /// @notice Chain ID → IBC route mapping
    mapping(uint256 => IbcRoute) private _routes;

    /// @notice Supported chain IDs
    uint256[] public supportedChains;

    /// @notice Processed packet deduplication
    mapping(bytes32 => bool) public processedPackets;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error UnsupportedChain(uint256 chainId);
    error IbcSendFailed();
    error PacketAlreadyProcessed(bytes32 packetId);

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor() {
        governance = msg.sender;
    }

    // ── IBridgeAdapter ─────────────────────────────────────────────────

    /// @inheritdoc IBridgeAdapter
    function sendMessage(
        uint256 destinationChainId,
        address /* recipient — IBC uses port/channel addressing */,
        bytes calldata payload,
        uint256 /* gasLimit — not applicable for IBC */
    ) external payable returns (bytes32 messageId) {
        IbcRoute storage route = _routes[destinationChainId];
        if (bytes(route.channelId).length == 0)
            revert UnsupportedChain(destinationChainId);

        // Encode privacy payload as IBC packet data
        bytes memory packetData = abi.encode(
            block.chainid,
            msg.sender,
            payload
        );

        // Call IBC precompile to send packet
        (bool success, bytes memory result) = IBC_PRECOMPILE.call(
            abi.encodeWithSignature(
                "transfer(string,string,uint256,string,string,uint64,uint64,string)",
                route.portId,
                route.channelId,
                0, // amount (we're sending data, not tokens)
                "", // denom
                "", // receiver (encoded in payload)
                route.timeoutHeight,
                route.timeoutTimestamp,
                string(packetData) // memo field carries the privacy payload
            )
        );
        if (!success) revert IbcSendFailed();

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
        // IBC packet reception is handled by the IBC module
        // This function is called by the IBC acknowledgement handler
        bytes32 packetId = keccak256(
            abi.encodePacked(sourceChainId, sender, block.number, payload)
        );

        if (processedPackets[packetId]) revert PacketAlreadyProcessed(packetId);
        processedPackets[packetId] = true;

        emit MessageReceived(sourceChainId, packetId, sender, payload);
    }

    /// @inheritdoc IBridgeAdapter
    function estimateFee(
        uint256 /* destinationChainId */,
        bytes calldata /* payload */,
        uint256 /* gasLimit */
    ) external pure returns (uint256 fee) {
        // IBC relay fees are paid by relayers (incentivized off-chain)
        return 0;
    }

    /// @inheritdoc IBridgeAdapter
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return
            bytes(_routes[chainId].channelId).length > 0 &&
            _routes[chainId].active;
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProtocol() external pure returns (string memory) {
        return "IBC";
    }

    // ── Governance ─────────────────────────────────────────────────────

    function registerRoute(
        uint256 chainId,
        string calldata portId,
        string calldata channelId,
        uint64 timeoutHeight,
        uint64 timeoutTimestamp
    ) external onlyGovernance {
        _routes[chainId] = IbcRoute({
            portId: portId,
            channelId: channelId,
            timeoutHeight: timeoutHeight,
            timeoutTimestamp: timeoutTimestamp,
            active: true
        });
        supportedChains.push(chainId);
    }

    function setRouteActive(
        uint256 chainId,
        bool active
    ) external onlyGovernance {
        _routes[chainId].active = active;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }
}
