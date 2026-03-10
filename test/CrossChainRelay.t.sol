// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

// ── Minimal interfaces for testing ─────────────────────

interface IPool {
    function deposit(bytes32 commitment, uint256 amount) external payable;

    function getLatestRoot() external view returns (bytes32);

    function getNextLeafIndex() external view returns (uint256);

    function poolBalance() external view returns (uint256);

    function paused() external view returns (bool);
}

interface IEpoch {
    function currentEpochId() external view returns (uint256);

    function registerNullifier(bytes32 nullifier) external;

    function finalizeEpoch() external;

    function receiveRemoteRoot(
        uint256 sourceChainId,
        uint256 epochId,
        bytes32 nullifierRoot
    ) external;

    function getRemoteEpochRoot(
        uint256 sourceChainId,
        uint256 epochId
    ) external view returns (bytes32);
}

// ── Mock Bridge Adapter ────────────────────────────────

/// @dev Simulates a cross-chain bridge by directly calling receiveRemoteRoot
///      on the destination epoch manager. In production, AWM/Teleporter/XCM
///      would deliver the message asynchronously.
contract MockBridgeAdapter {
    struct PendingMessage {
        uint256 sourceChainId;
        uint256 epochId;
        bytes32 nullifierRoot;
        address destEpochManager;
    }

    PendingMessage[] public pendingMessages;

    event MessageQueued(
        uint256 indexed sourceChainId,
        uint256 indexed epochId,
        bytes32 nullifierRoot,
        address destEpochManager
    );

    event MessageDelivered(
        uint256 indexed sourceChainId,
        uint256 indexed epochId,
        address destEpochManager
    );

    /// @notice Queue a relay message (simulates sending cross-chain).
    function queueRelay(
        uint256 sourceChainId,
        uint256 epochId,
        bytes32 nullifierRoot,
        address destEpochManager
    ) external {
        pendingMessages.push(
            PendingMessage({
                sourceChainId: sourceChainId,
                epochId: epochId,
                nullifierRoot: nullifierRoot,
                destEpochManager: destEpochManager
            })
        );

        emit MessageQueued(
            sourceChainId,
            epochId,
            nullifierRoot,
            destEpochManager
        );
    }

    /// @notice Deliver all pending messages to their destinations.
    function deliverAll() external {
        for (uint256 i = 0; i < pendingMessages.length; i++) {
            PendingMessage memory msg_ = pendingMessages[i];
            IEpoch(msg_.destEpochManager).receiveRemoteRoot(
                msg_.sourceChainId,
                msg_.epochId,
                msg_.nullifierRoot
            );

            emit MessageDelivered(
                msg_.sourceChainId,
                msg_.epochId,
                msg_.destEpochManager
            );
        }
        delete pendingMessages;
    }

    /// @notice Get number of queued messages.
    function pendingCount() external view returns (uint256) {
        return pendingMessages.length;
    }
}

// ── Mock Verifier (always passes) ──────────────────────

contract MockVerifier {
    function verifyTransferProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function verifyWithdrawProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function verifyAggregatedProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function provingSystem() external pure returns (string memory) {
        return "mock";
    }
}

// ── Mock EpochManager (simplified) ─────────────────────

contract MockEpochManager {
    uint256 public currentEpochId;
    uint256 public immutable epochDuration;
    uint256 public immutable domainChainId;
    address public pool;
    address public governance;

    mapping(address => bool) public authorizedPools;
    mapping(address => bool) public authorizedBridges;
    mapping(bytes32 => bytes32) public remoteEpochRoots;
    mapping(bytes32 => bool) public localNullifiers;

    bytes32[] private _currentEpochNullifiers;
    mapping(uint256 => bytes32) public epochRoots;

    error Unauthorized();

    constructor(uint256 _domainChainId, uint256 _epochDuration, address _pool) {
        domainChainId = _domainChainId;
        epochDuration = _epochDuration;
        pool = _pool;
        governance = msg.sender;
        authorizedPools[_pool] = true;
    }

    function authorizeBridge(address bridge) external {
        require(msg.sender == governance, "not gov");
        authorizedBridges[bridge] = true;
    }

    function authorizePool(address _pool) external {
        require(msg.sender == governance, "not gov");
        authorizedPools[_pool] = true;
    }

    function registerNullifier(bytes32 nullifier) external {
        if (!authorizedPools[msg.sender]) revert Unauthorized();
        localNullifiers[nullifier] = true;
        _currentEpochNullifiers.push(nullifier);
    }

    function finalizeEpoch() external {
        // Compute a simple root hash for the epoch
        bytes32 root = keccak256(abi.encodePacked(_currentEpochNullifiers));
        epochRoots[currentEpochId] = root;
        currentEpochId++;
        delete _currentEpochNullifiers;
    }

    function receiveRemoteRoot(
        uint256 sourceChainId,
        uint256 epochId,
        bytes32 nullifierRoot
    ) external {
        if (!authorizedBridges[msg.sender]) revert Unauthorized();
        bytes32 key = keccak256(abi.encodePacked(sourceChainId, epochId));
        remoteEpochRoots[key] = nullifierRoot;
    }

    function getRemoteEpochRoot(
        uint256 sourceChainId,
        uint256 epochId
    ) external view returns (bytes32) {
        bytes32 key = keccak256(abi.encodePacked(sourceChainId, epochId));
        return remoteEpochRoots[key];
    }

    function getEpochRoot(uint256 epochId) external view returns (bytes32) {
        return epochRoots[epochId];
    }
}

// ══════════════════════════════════════════════════════════
//  Cross-Chain Relay Integration Tests
// ══════════════════════════════════════════════════════════

contract CrossChainRelayTest is Test {
    // Chain A (Avalanche — chainId: 43114)
    MockVerifier verifierA;
    MockEpochManager epochManagerA;
    MockBridgeAdapter bridgeAtoB;

    // Chain B (Moonbeam — chainId: 1284)
    MockVerifier verifierB;
    MockEpochManager epochManagerB;
    MockBridgeAdapter bridgeBtoA;

    address alice = makeAddr("alice");
    address relayer = makeAddr("relayer");
    address guardian = makeAddr("guardian");

    uint256 constant CHAIN_A_ID = 43114;
    uint256 constant CHAIN_B_ID = 1284;
    uint256 constant EPOCH_DURATION = 3600;

    function setUp() public {
        // Deploy Chain A infrastructure
        verifierA = new MockVerifier();
        epochManagerA = new MockEpochManager(
            CHAIN_A_ID,
            EPOCH_DURATION,
            address(0) // Pool will be set later
        );
        bridgeAtoB = new MockBridgeAdapter();

        // Deploy Chain B infrastructure
        verifierB = new MockVerifier();
        epochManagerB = new MockEpochManager(
            CHAIN_B_ID,
            EPOCH_DURATION,
            address(0)
        );
        bridgeBtoA = new MockBridgeAdapter();

        // Authorize bridges on both epoch managers
        epochManagerA.authorizeBridge(address(bridgeBtoA));
        epochManagerB.authorizeBridge(address(bridgeAtoB));
    }

    // ── Test: Single-chain epoch finalization ──────────

    function test_singleChainEpochFinalize() public {
        // Register some nullifiers on Chain A
        epochManagerA.authorizePool(address(this));
        epochManagerA.registerNullifier(bytes32(uint256(1)));
        epochManagerA.registerNullifier(bytes32(uint256(2)));
        epochManagerA.registerNullifier(bytes32(uint256(3)));

        assertEq(epochManagerA.currentEpochId(), 0);

        // Finalize epoch 0
        epochManagerA.finalizeEpoch();
        assertEq(epochManagerA.currentEpochId(), 1);

        // Epoch root should be set
        bytes32 root = epochManagerA.getEpochRoot(0);
        assertTrue(root != bytes32(0), "Epoch root should be non-zero");
    }

    // ── Test: Cross-chain epoch root relay A→B ─────────

    function test_crossChainRelayAtoB() public {
        // Register nullifiers on Chain A
        epochManagerA.authorizePool(address(this));
        epochManagerA.registerNullifier(bytes32(uint256(100)));
        epochManagerA.registerNullifier(bytes32(uint256(200)));

        // Finalize epoch on Chain A
        epochManagerA.finalizeEpoch();
        bytes32 epochRoot = epochManagerA.getEpochRoot(0);

        // Relayer queues the message for Chain B
        bridgeAtoB.queueRelay(CHAIN_A_ID, 0, epochRoot, address(epochManagerB));
        assertEq(bridgeAtoB.pendingCount(), 1);

        // Bridge delivers
        bridgeAtoB.deliverAll();
        assertEq(bridgeAtoB.pendingCount(), 0);

        // Chain B should now have the remote root from Chain A
        bytes32 remoteRoot = epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0);
        assertEq(remoteRoot, epochRoot, "Remote root mismatch");
    }

    // ── Test: Bidirectional relay A↔B ──────────────────

    function test_bidirectionalRelay() public {
        // Chain A: register + finalize
        epochManagerA.authorizePool(address(this));
        epochManagerA.registerNullifier(bytes32(uint256(10)));
        epochManagerA.finalizeEpoch();
        bytes32 rootA = epochManagerA.getEpochRoot(0);

        // Chain B: register + finalize
        epochManagerB.authorizePool(address(this));
        epochManagerB.registerNullifier(bytes32(uint256(20)));
        epochManagerB.finalizeEpoch();
        bytes32 rootB = epochManagerB.getEpochRoot(0);

        // Relay A→B
        bridgeAtoB.queueRelay(CHAIN_A_ID, 0, rootA, address(epochManagerB));
        bridgeAtoB.deliverAll();

        // Relay B→A
        bridgeBtoA.queueRelay(CHAIN_B_ID, 0, rootB, address(epochManagerA));
        bridgeBtoA.deliverAll();

        // Verify both sides received the other's root
        assertEq(epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0), rootA);
        assertEq(epochManagerA.getRemoteEpochRoot(CHAIN_B_ID, 0), rootB);
    }

    // ── Test: Multi-epoch relay ────────────────────────

    function test_multiEpochRelay() public {
        epochManagerA.authorizePool(address(this));

        // Finalize 3 epochs on Chain A
        for (uint256 i = 0; i < 3; i++) {
            epochManagerA.registerNullifier(bytes32(i + 1000));
            epochManagerA.finalizeEpoch();
        }

        assertEq(epochManagerA.currentEpochId(), 3);

        // Relay all 3 epochs to Chain B
        for (uint256 i = 0; i < 3; i++) {
            bridgeAtoB.queueRelay(
                CHAIN_A_ID,
                i,
                epochManagerA.getEpochRoot(i),
                address(epochManagerB)
            );
        }

        assertEq(bridgeAtoB.pendingCount(), 3);
        bridgeAtoB.deliverAll();

        // Verify all 3 remote roots
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, i),
                epochManagerA.getEpochRoot(i)
            );
        }
    }

    // ── Test: Unauthorized bridge rejected ─────────────

    function test_unauthorizedBridgeRejected() public {
        MockBridgeAdapter rogue = new MockBridgeAdapter();

        epochManagerA.authorizePool(address(this));
        epochManagerA.registerNullifier(bytes32(uint256(999)));
        epochManagerA.finalizeEpoch();

        rogue.queueRelay(
            CHAIN_A_ID,
            0,
            epochManagerA.getEpochRoot(0),
            address(epochManagerB)
        );

        // Delivery should revert because the rogue bridge is not authorized
        vm.expectRevert(MockEpochManager.Unauthorized.selector);
        rogue.deliverAll();
    }

    // ── Test: Different epochs produce different roots ─

    function test_differentEpochsDifferentRoots() public {
        epochManagerA.authorizePool(address(this));

        epochManagerA.registerNullifier(bytes32(uint256(1)));
        epochManagerA.finalizeEpoch();
        bytes32 root0 = epochManagerA.getEpochRoot(0);

        epochManagerA.registerNullifier(bytes32(uint256(2)));
        epochManagerA.finalizeEpoch();
        bytes32 root1 = epochManagerA.getEpochRoot(1);

        assertTrue(
            root0 != root1,
            "Different epochs should have different roots"
        );
    }

    // ── Test: Empty epoch root ─────────────────────────

    function test_emptyEpochRoot() public {
        epochManagerA.authorizePool(address(this));
        // Finalize without registering any nullifiers
        epochManagerA.finalizeEpoch();

        bytes32 root = epochManagerA.getEpochRoot(0);
        // Empty epoch still produces a root (keccak of empty array)
        assertTrue(root != bytes32(0), "Empty epoch should still have a root");
    }

    // ── Test: Relay idempotency (overwrite) ────────────

    function test_relayOverwrite() public {
        epochManagerA.authorizePool(address(this));
        epochManagerA.registerNullifier(bytes32(uint256(42)));
        epochManagerA.finalizeEpoch();
        bytes32 root0 = epochManagerA.getEpochRoot(0);

        // Relay once
        bridgeAtoB.queueRelay(CHAIN_A_ID, 0, root0, address(epochManagerB));
        bridgeAtoB.deliverAll();

        bytes32 received1 = epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0);

        // Relay again (same data) — should succeed and be idempotent
        bridgeAtoB.queueRelay(CHAIN_A_ID, 0, root0, address(epochManagerB));
        bridgeAtoB.deliverAll();

        bytes32 received2 = epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0);
        assertEq(received1, received2, "Relay should be idempotent");
    }

    // ── Test: Batch relay from multiple sources ────────

    function test_batchRelayFromMultipleSources() public {
        // Deploy a third chain (Evmos - 9001)
        MockEpochManager epochManagerC = new MockEpochManager(
            9001,
            EPOCH_DURATION,
            address(0)
        );
        MockBridgeAdapter bridgeCtoA = new MockBridgeAdapter();
        epochManagerA.authorizeBridge(address(bridgeCtoA));

        // Chain B finalizes
        epochManagerB.authorizePool(address(this));
        epochManagerB.registerNullifier(bytes32(uint256(500)));
        epochManagerB.finalizeEpoch();

        // Chain C finalizes
        epochManagerC.authorizePool(address(this));
        epochManagerC.registerNullifier(bytes32(uint256(600)));
        epochManagerC.finalizeEpoch();

        // Both relay to Chain A
        bridgeBtoA.queueRelay(
            CHAIN_B_ID,
            0,
            epochManagerB.getEpochRoot(0),
            address(epochManagerA)
        );
        bridgeBtoA.deliverAll();

        bridgeCtoA.queueRelay(
            9001,
            0,
            epochManagerC.getEpochRoot(0),
            address(epochManagerA)
        );
        bridgeCtoA.deliverAll();

        // Chain A has roots from both B and C
        assertTrue(
            epochManagerA.getRemoteEpochRoot(CHAIN_B_ID, 0) != bytes32(0)
        );
        assertTrue(epochManagerA.getRemoteEpochRoot(9001, 0) != bytes32(0));

        // They should be different roots
        assertTrue(
            epochManagerA.getRemoteEpochRoot(CHAIN_B_ID, 0) !=
                epochManagerA.getRemoteEpochRoot(9001, 0)
        );
    }

    // ── Test: Full lifecycle simulation ────────────────

    function test_fullLifecycle() public {
        // Setup: authorize pools
        epochManagerA.authorizePool(address(this));
        epochManagerB.authorizePool(address(this));

        // Step 1: Deposits on both chains (simulated as nullifier registrations)
        epochManagerA.registerNullifier(bytes32(uint256(1)));
        epochManagerA.registerNullifier(bytes32(uint256(2)));
        epochManagerB.registerNullifier(bytes32(uint256(3)));

        // Step 2: Time passes → finalize epochs
        epochManagerA.finalizeEpoch();
        epochManagerB.finalizeEpoch();

        // Step 3: Relayer relays roots both directions
        bridgeAtoB.queueRelay(
            CHAIN_A_ID,
            0,
            epochManagerA.getEpochRoot(0),
            address(epochManagerB)
        );
        bridgeBtoA.queueRelay(
            CHAIN_B_ID,
            0,
            epochManagerB.getEpochRoot(0),
            address(epochManagerA)
        );

        bridgeAtoB.deliverAll();
        bridgeBtoA.deliverAll();

        // Step 4: Both chains know each other's nullifier roots
        assertEq(
            epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0),
            epochManagerA.getEpochRoot(0)
        );
        assertEq(
            epochManagerA.getRemoteEpochRoot(CHAIN_B_ID, 0),
            epochManagerB.getEpochRoot(0)
        );

        // Step 5: New epoch with more activity
        epochManagerA.registerNullifier(bytes32(uint256(4)));
        epochManagerA.finalizeEpoch();

        bridgeAtoB.queueRelay(
            CHAIN_A_ID,
            1,
            epochManagerA.getEpochRoot(1),
            address(epochManagerB)
        );
        bridgeAtoB.deliverAll();

        // Chain B now has epoch 0 and epoch 1 from Chain A
        assertTrue(
            epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0) != bytes32(0)
        );
        assertTrue(
            epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 1) != bytes32(0)
        );
        assertTrue(
            epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 0) !=
                epochManagerB.getRemoteEpochRoot(CHAIN_A_ID, 1)
        );
    }
}

// ══════════════════════════════════════════════════════════
//  MultiSig Governance Integration Tests
// ══════════════════════════════════════════════════════════

interface IMultiSig {
    function submitProposal(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (uint256);

    function confirmProposal(uint256 proposalId) external;

    function executeProposal(uint256 proposalId) external;

    function isExecutable(uint256 proposalId) external view returns (bool);

    function getOwnerCount() external view returns (uint256);

    function threshold() external view returns (uint256);
}

contract MultiSigIntegrationTest is Test {
    // Simple counter to use as a governance target
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }

    function test_placeholder() public pure {
        // Placeholder — MultiSig tested in GovernancePauseStealth.t.sol
        // This file focuses on cross-chain relay integration
        assertTrue(true);
    }
}
