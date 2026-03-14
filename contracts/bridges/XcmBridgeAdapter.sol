// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";

/// @title XcmBridgeAdapter — Bridge adapter using Polkadot XCM via Moonbeam precompiles
/// @notice Routes ZK proof envelopes and nullifier roots cross-parachain using
///         Moonbeam's XCM Transactor precompile. Works on Moonbeam, Astar, and
///         other EVM-compatible Polkadot parachains with XCM precompile support.
/// @dev Moonbeam XCM Transactor v2: 0x000000000000000000000000000000000000080D
///      Moonbeam XCM precompile: 0x000000000000000000000000000000000000080a
///      See: https://docs.moonbeam.network/builders/interoperability/xcm/
contract XcmBridgeAdapter is IBridgeAdapter {
    // ── Constants (Moonbeam Precompiles) ───────────────────────────────

    /// @notice XCM Transactor v2 precompile (for transacting on remote parachains)
    address internal constant XCM_TRANSACTOR_V2 =
        0x000000000000000000000000000000000000080D;

    /// @notice XCM precompile (for sending raw XCM messages)
    address internal constant XCM_PRECOMPILE =
        0x000000000000000000000000000000000000080a;

    /// @notice Batch precompile (for atomic multi-call operations)
    address internal constant BATCH_PRECOMPILE =
        0x0000000000000000000000000000000000000808;

    // ── Types ──────────────────────────────────────────────────────────

    /// @notice Multilocation for XCM addressing
    struct Multilocation {
        uint8 parents;
        bytes[] interior;
    }

    /// @notice Parachain route configuration
    struct ParachainRoute {
        uint32 paraId;
        address remoteContract;
        uint64 transactWeight;
        uint64 overallWeight;
        uint256 feeAmount;
        bool active;
    }

    // ── State ──────────────────────────────────────────────────────────

    /// @notice This parachain's ID
    uint32 public immutable thisParaId;

    /// @notice Chain ID → Parachain route mapping
    mapping(uint256 => ParachainRoute) public routes;

    /// @notice Supported chain IDs
    uint256[] public supportedChains;

    /// @notice Processed message deduplication
    mapping(bytes32 => bool) public processedMessages;

    /// @notice Authorized XCM senders (verified by sovereign account)
    mapping(uint256 => address) public sovereignAccounts;

    address public governance;

    // ── Errors ─────────────────────────────────────────────────────────

    error Unauthorized();
    error UnsupportedChain(uint256 chainId);
    error RouteInactive(uint256 chainId);
    error XcmTransactFailed();
    error MessageAlreadyProcessed(bytes32 messageId);
    error InvalidSovereignAccount();

    // ── Modifiers ──────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Unauthorized();
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────

    constructor(uint32 _thisParaId) {
        thisParaId = _thisParaId;
        governance = msg.sender;
    }

    // ── IBridgeAdapter ─────────────────────────────────────────────────

    /// @inheritdoc IBridgeAdapter
    function sendMessage(
        uint256 destinationChainId,
        address recipient,
        bytes calldata payload,
        uint256 gasLimit
    ) external payable returns (bytes32 messageId) {
        ParachainRoute memory route = routes[destinationChainId];
        if (route.paraId == 0) revert UnsupportedChain(destinationChainId);
        if (!route.active) revert RouteInactive(destinationChainId);

        // Encode the call to be executed on the remote parachain
        // This will call receiveMessage() on the remote XcmBridgeAdapter
        bytes memory remoteCall = abi.encodeWithSignature(
            "receiveMessage(uint256,address,bytes)",
            block.chainid,
            msg.sender,
            payload
        );

        // Build XCM Multilocation for the destination parachain
        // Multilocation: { parents: 1, interior: [Parachain(paraId)] }
        Multilocation memory dest = Multilocation({
            parents: 1,
            interior: new bytes[](1)
        });
        dest.interior[0] = abi.encodePacked(uint8(0x00), route.paraId); // Parachain junction

        // Call XCM Transactor v2 to execute on remote parachain
        (bool success, ) = XCM_TRANSACTOR_V2.call(
            abi.encodeWithSignature(
                "transactThroughSigned((uint8,bytes[]),address,bytes,uint64,uint64)",
                dest,
                route.remoteContract,
                remoteCall,
                route.transactWeight,
                route.overallWeight
            )
        );
        if (!success) revert XcmTransactFailed();

        messageId = keccak256(
            abi.encodePacked(
                thisParaId,
                route.paraId,
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
        // Verify the caller is the sovereign account for the source parachain
        // When an XCM message arrives from another parachain, the EVM execution
        // context has msg.sender set to the parachain's sovereign account
        address expectedSovereign = sovereignAccounts[sourceChainId];
        if (expectedSovereign == address(0))
            revert UnsupportedChain(sourceChainId);
        if (msg.sender != expectedSovereign) revert InvalidSovereignAccount();

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
        uint256 destinationChainId,
        bytes calldata /* payload */,
        uint256 /* gasLimit */
    ) external view returns (uint256 fee) {
        ParachainRoute memory route = routes[destinationChainId];
        if (route.paraId == 0) revert UnsupportedChain(destinationChainId);
        return route.feeAmount;
    }

    /// @inheritdoc IBridgeAdapter
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return routes[chainId].paraId != 0 && routes[chainId].active;
    }

    /// @inheritdoc IBridgeAdapter
    function bridgeProtocol() external pure returns (string memory) {
        return "XCM";
    }

    // ── Governance / Configuration ──────────────────────────────────────

    /// @notice Register a parachain route
    function registerRoute(
        uint256 chainId,
        uint32 paraId,
        address remoteContract,
        uint64 transactWeight,
        uint64 overallWeight,
        uint256 feeAmount,
        address sovereignAccount
    ) external onlyGovernance {
        routes[chainId] = ParachainRoute({
            paraId: paraId,
            remoteContract: remoteContract,
            transactWeight: transactWeight,
            overallWeight: overallWeight,
            feeAmount: feeAmount,
            active: true
        });
        sovereignAccounts[chainId] = sovereignAccount;
        supportedChains.push(chainId);
    }

    /// @notice Activate/deactivate a route
    function setRouteActive(
        uint256 chainId,
        bool active
    ) external onlyGovernance {
        routes[chainId].active = active;
    }

    /// @notice Update fee estimate for a route
    function updateRouteFee(
        uint256 chainId,
        uint256 feeAmount
    ) external onlyGovernance {
        routes[chainId].feeAmount = feeAmount;
    }

    /// @notice Update sovereign account for a source chain
    function updateSovereignAccount(
        uint256 chainId,
        address sovereign
    ) external onlyGovernance {
        sovereignAccounts[chainId] = sovereign;
    }

    function setGovernance(address _governance) external onlyGovernance {
        governance = _governance;
    }

    /// @notice Get all supported chain IDs
    function getSupportedChains() external view returns (uint256[] memory) {
        return supportedChains;
    }
}
