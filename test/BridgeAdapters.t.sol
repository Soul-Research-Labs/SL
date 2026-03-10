// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";
import "../contracts/bridges/AvaxWarpAdapter.sol";
import "../contracts/bridges/TeleporterAdapter.sol";
import "../contracts/bridges/XcmBridgeAdapter.sol";
import "../contracts/bridges/IbcBridgeAdapter.sol";
import "../contracts/bridges/AuroraRainbowAdapter.sol";

// ── Helpers ──────────────────────────────────────────────────

/// @notice Minimal mock bridge adapter for testing the registry
contract MockBridgeAdapter {
    function bridgeProtocol() external pure returns (string memory) {
        return "mock";
    }
}

// ══════════════════════════════════════════════════════════════
//  UniversalNullifierRegistry Tests
// ══════════════════════════════════════════════════════════════

contract UniversalNullifierRegistryTest is Test {
    UniversalNullifierRegistry public registry;
    MockBridgeAdapter public mockBridge;

    address public gov = address(1);
    address public attacker = address(99);

    uint256 constant AVAX_CHAIN = 43114;
    uint256 constant MOONBEAM_CHAIN = 1284;
    uint256 constant ASTAR_CHAIN = 592;

    function setUp() public {
        vm.startPrank(gov);
        registry = new UniversalNullifierRegistry();
        mockBridge = new MockBridgeAdapter();
        vm.stopPrank();
    }

    // ── Registration ───────────────────────────────────────────

    function test_registerChain() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        (
            uint256 chainId,
            string memory name,
            address bridge,
            ,
            ,
            ,
            bool active
        ) = registry.chains(AVAX_CHAIN);

        assertEq(chainId, AVAX_CHAIN);
        assertEq(name, "Avalanche");
        assertEq(bridge, address(mockBridge));
        assertTrue(active);
    }

    function test_registerChain_onlyGovernance() public {
        vm.prank(attacker);
        vm.expectRevert(UniversalNullifierRegistry.Unauthorized.selector);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
    }

    function test_registerChain_duplicate_reverts() public {
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainAlreadyRegistered.selector,
                AVAX_CHAIN
            )
        );
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        vm.stopPrank();
    }

    function test_deactivateChain() public {
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        registry.deactivateChain(AVAX_CHAIN);
        vm.stopPrank();

        (, , , , , , bool active) = registry.chains(AVAX_CHAIN);
        assertFalse(active);
    }

    // ── Epoch Root Submission ──────────────────────────────────

    function test_submitEpochRoot() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        bytes32 root = keccak256("epoch-0-root");

        vm.prank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, root, 42);

        assertEq(registry.epochRoots(AVAX_CHAIN, 0), root);

        (, , , uint256 latestEpochId, bytes32 latestRoot, , ) = registry.chains(
            AVAX_CHAIN
        );
        assertEq(latestEpochId, 0);
        assertEq(latestRoot, root);
    }

    function test_submitEpochRoot_unauthorizedBridge_reverts() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        vm.prank(attacker);
        vm.expectRevert(UniversalNullifierRegistry.Unauthorized.selector);
        registry.submitEpochRoot(AVAX_CHAIN, 0, bytes32(uint256(1)), 10);
    }

    function test_submitEpochRoot_sequentialValidation() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        vm.startPrank(address(mockBridge));

        // Epoch 0 should succeed
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("root-0"), 10);

        // Epoch 1 should succeed
        registry.submitEpochRoot(AVAX_CHAIN, 1, keccak256("root-1"), 20);

        // Epoch 3 (skipping 2) should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.InvalidEpochSequence.selector,
                AVAX_CHAIN,
                2,
                3
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN, 3, keccak256("root-3"), 30);

        vm.stopPrank();
    }

    function test_submitEpochRoot_duplicateEpoch_reverts() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        vm.startPrank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("root-0"), 10);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.EpochAlreadyRecorded.selector,
                AVAX_CHAIN,
                0
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("root-0-dup"), 10);
        vm.stopPrank();
    }

    function test_submitEpochRoot_inactiveChain_reverts() public {
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        registry.deactivateChain(AVAX_CHAIN);
        vm.stopPrank();

        vm.prank(address(mockBridge));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainInactive.selector,
                AVAX_CHAIN
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("root"), 10);
    }

    // ── Global Snapshot ────────────────────────────────────────

    function test_createGlobalSnapshot() public {
        // Register and submit roots for two chains
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        registry.registerChain(MOONBEAM_CHAIN, "Moonbeam", address(mockBridge));
        vm.stopPrank();

        vm.startPrank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("avax-root"), 10);
        registry.submitEpochRoot(
            MOONBEAM_CHAIN,
            0,
            keccak256("moonbeam-root"),
            20
        );
        vm.stopPrank();

        // Create snapshot
        vm.prank(gov);
        registry.createGlobalSnapshot();

        bytes32 newGlobal = registry.globalRoot();
        assertTrue(newGlobal != bytes32(0), "Global root should not be zero");
    }

    function test_createGlobalSnapshot_multipleChains() public {
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        registry.registerChain(MOONBEAM_CHAIN, "Moonbeam", address(mockBridge));
        registry.registerChain(ASTAR_CHAIN, "Astar", address(mockBridge));
        vm.stopPrank();

        vm.startPrank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, keccak256("avax"), 10);
        registry.submitEpochRoot(MOONBEAM_CHAIN, 0, keccak256("moon"), 20);
        registry.submitEpochRoot(ASTAR_CHAIN, 0, keccak256("astar"), 30);
        vm.stopPrank();

        vm.prank(gov);
        registry.createGlobalSnapshot();

        (uint256 snapshotId, , , uint256 chainCount) = registry.snapshots(0);
        assertEq(snapshotId, 0);
        assertEq(chainCount, 3);
    }

    // ── Nullifier Reporting ────────────────────────────────────

    function test_reportNullifierSpent() public {
        vm.prank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));

        // Submit epoch root
        bytes32 epochRoot = keccak256("nullifier-tree-root");
        vm.prank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, epochRoot, 1);

        // Report nullifier as spent (with proof)
        bytes32 nullifier = keccak256("test-nullifier");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");

        vm.prank(address(mockBridge));
        registry.reportNullifierSpent(AVAX_CHAIN, nullifier, 0, proof);

        assertTrue(registry.nullifierSpentGlobal(AVAX_CHAIN, nullifier));
    }

    function test_isNullifierSpentGlobally() public {
        vm.startPrank(gov);
        registry.registerChain(AVAX_CHAIN, "Avalanche", address(mockBridge));
        registry.registerChain(MOONBEAM_CHAIN, "Moonbeam", address(mockBridge));
        vm.stopPrank();

        bytes32 nullifier = keccak256("test-nullifier");

        // Not spent anywhere yet
        assertFalse(registry.isNullifierSpentGlobally(nullifier));

        // Submit root and report on Avalanche
        bytes32 root = keccak256("root");
        vm.startPrank(address(mockBridge));
        registry.submitEpochRoot(AVAX_CHAIN, 0, root, 1);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("sibling");
        registry.reportNullifierSpent(AVAX_CHAIN, nullifier, 0, proof);
        vm.stopPrank();

        assertTrue(registry.isNullifierSpentGlobally(nullifier));
    }
}

// ══════════════════════════════════════════════════════════════
//  Bridge Adapter Unit Tests
// ══════════════════════════════════════════════════════════════

contract AvaxWarpAdapterTest is Test {
    AvaxWarpAdapter public adapter;
    address public gov = address(1);

    function setUp() public {
        vm.prank(gov);
        adapter = new AvaxWarpAdapter();
    }

    function test_bridgeProtocol() public view {
        assertEq(adapter.bridgeProtocol(), "AWM");
    }

    function test_unsupported_chain() public view {
        assertFalse(adapter.isChainSupported(999999));
    }

    function test_sendMessage_unsuppported_reverts() public {
        vm.prank(gov);
        vm.expectRevert();
        adapter.sendMessage(999999, address(0), bytes("payload"), 100000);
    }

    function test_governance() public view {
        assertEq(adapter.governance(), gov);
    }
}

contract TeleporterAdapterTest is Test {
    TeleporterAdapter public adapter;
    address public gov = address(1);

    function setUp() public {
        vm.prank(gov);
        adapter = new TeleporterAdapter();
    }

    function test_bridgeProtocol() public view {
        assertEq(adapter.bridgeProtocol(), "Teleporter");
    }

    function test_unsupported_chain() public view {
        assertFalse(adapter.isChainSupported(999999));
    }

    function test_governance() public view {
        assertEq(adapter.governance(), gov);
    }
}

contract XcmBridgeAdapterTest is Test {
    XcmBridgeAdapter public adapter;
    address public gov = address(1);

    function setUp() public {
        vm.prank(gov);
        adapter = new XcmBridgeAdapter(2004); // Moonbeam paraId
    }

    function test_bridgeProtocol() public view {
        assertEq(adapter.bridgeProtocol(), "XCM");
    }

    function test_thisParaId() public view {
        assertEq(adapter.thisParaId(), 2004);
    }

    function test_unsupported_chain() public view {
        assertFalse(adapter.isChainSupported(999999));
    }

    function test_governance() public view {
        assertEq(adapter.governance(), gov);
    }
}

contract IbcBridgeAdapterTest is Test {
    IbcBridgeAdapter public adapter;
    address public gov = address(1);

    function setUp() public {
        vm.prank(gov);
        adapter = new IbcBridgeAdapter();
    }

    function test_bridgeProtocol() public view {
        assertEq(adapter.bridgeProtocol(), "IBC");
    }

    function test_unsupported_chain() public view {
        assertFalse(adapter.isChainSupported(999999));
    }

    function test_governance() public view {
        assertEq(adapter.governance(), gov);
    }
}

contract AuroraRainbowAdapterTest is Test {
    AuroraRainbowAdapter public adapter;
    address public gov = address(1);

    function setUp() public {
        vm.prank(gov);
        adapter = new AuroraRainbowAdapter();
    }

    function test_bridgeProtocol() public view {
        assertEq(adapter.bridgeProtocol(), "Rainbow");
    }

    function test_unsupported_chain() public view {
        assertFalse(adapter.isChainSupported(999999));
    }

    function test_governance() public view {
        assertEq(adapter.governance(), gov);
    }
}
