// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";

contract UniversalNullifierRegistryTest is Test {
    UniversalNullifierRegistry public registry;

    address public governance = address(1);
    address public bridgeAvax = address(2);
    address public bridgeMoon = address(3);
    address public alice = address(4);

    uint256 constant AVAX_CHAIN_ID = 43114;
    uint256 constant MOON_CHAIN_ID = 1284;

    function setUp() public {
        vm.prank(governance);
        registry = new UniversalNullifierRegistry(governance);
    }

    // ── Chain Registration ────────────────────────────

    function test_registerChain() public {
        vm.prank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);

        (uint256 chainId, , address adapter, , , , bool active) = registry
            .chains(AVAX_CHAIN_ID);

        assertEq(chainId, AVAX_CHAIN_ID);
        assertEq(adapter, bridgeAvax);
        assertTrue(active);
        assertEq(registry.getRegisteredChainCount(), 1);
    }

    function test_registerChain_reverts_duplicate() public {
        vm.startPrank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainAlreadyRegistered.selector,
                AVAX_CHAIN_ID
            )
        );
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche2", bridgeAvax);
        vm.stopPrank();
    }

    function test_registerChain_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(UniversalNullifierRegistry.Unauthorized.selector);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
    }

    function test_deactivateChain() public {
        vm.startPrank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
        registry.deactivateChain(AVAX_CHAIN_ID);
        vm.stopPrank();

        (, , , , , , bool active) = registry.chains(AVAX_CHAIN_ID);
        assertFalse(active);
    }

    function test_deactivateChain_reverts_inactive() public {
        vm.startPrank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
        registry.deactivateChain(AVAX_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainInactive.selector,
                AVAX_CHAIN_ID
            )
        );
        registry.deactivateChain(AVAX_CHAIN_ID);
        vm.stopPrank();
    }

    function test_updateBridgeAdapter() public {
        address newBridge = address(99);

        vm.startPrank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
        registry.updateBridgeAdapter(AVAX_CHAIN_ID, newBridge);
        vm.stopPrank();

        (, , address adapter, , , , ) = registry.chains(AVAX_CHAIN_ID);
        assertEq(adapter, newBridge);
    }

    // ── Epoch Root Submission ─────────────────────────

    function _setupAvaxChain() internal {
        vm.prank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
    }

    function test_submitEpochRoot() public {
        _setupAvaxChain();
        bytes32 root = keccak256("epoch-root-1");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, root, 42);

        assertEq(registry.epochRoots(AVAX_CHAIN_ID, 1), root);

        (uint256 epochId, bytes32 latestRoot) = registry.getChainLatestEpoch(
            AVAX_CHAIN_ID
        );
        assertEq(epochId, 1);
        assertEq(latestRoot, root);
    }

    function test_submitEpochRoot_reverts_unauthorized() public {
        _setupAvaxChain();

        vm.prank(alice);
        vm.expectRevert(UniversalNullifierRegistry.Unauthorized.selector);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r"), 10);
    }

    function test_submitEpochRoot_reverts_duplicate() public {
        _setupAvaxChain();
        bytes32 root = keccak256("epoch-root-1");

        vm.startPrank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, root, 42);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.EpochAlreadyRecorded.selector,
                AVAX_CHAIN_ID,
                1
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, root, 42);
        vm.stopPrank();
    }

    function test_submitEpochRoot_sequential_epochs() public {
        _setupAvaxChain();

        vm.startPrank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r1"), 10);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 2, keccak256("r2"), 20);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 3, keccak256("r3"), 30);
        vm.stopPrank();

        (uint256 epochId, ) = registry.getChainLatestEpoch(AVAX_CHAIN_ID);
        assertEq(epochId, 3);
    }

    function test_submitEpochRoot_reverts_inactive_chain() public {
        _setupAvaxChain();

        vm.prank(governance);
        registry.deactivateChain(AVAX_CHAIN_ID);

        vm.prank(bridgeAvax);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainInactive.selector,
                AVAX_CHAIN_ID
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r"), 5);
    }

    // ── Governance can submit too ──────────────────────

    function test_governance_can_submit_epoch_root() public {
        _setupAvaxChain();

        vm.prank(governance);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("gov-root"), 5);

        assertEq(registry.epochRoots(AVAX_CHAIN_ID, 1), keccak256("gov-root"));
    }

    // ── Global Snapshot ───────────────────────────────

    function _setupTwoChains() internal {
        vm.startPrank(governance);
        registry.registerChain(AVAX_CHAIN_ID, "Avalanche", bridgeAvax);
        registry.registerChain(MOON_CHAIN_ID, "Moonbeam", bridgeMoon);
        vm.stopPrank();
    }

    function test_createGlobalSnapshot_empty() public {
        uint256 snapshotId = registry.createGlobalSnapshot();
        assertEq(snapshotId, 0);
        assertEq(registry.globalRoot(), bytes32(0));
    }

    function test_createGlobalSnapshot_single_chain() public {
        _setupAvaxChain();

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r1"), 10);

        registry.createGlobalSnapshot();

        assertTrue(registry.globalRoot() != bytes32(0));
        assertEq(registry.getSnapshotCount(), 1);
    }

    function test_createGlobalSnapshot_multi_chain() public {
        _setupTwoChains();

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("avax-r1"), 10);

        vm.prank(bridgeMoon);
        registry.submitEpochRoot(MOON_CHAIN_ID, 1, keccak256("moon-r1"), 20);

        registry.createGlobalSnapshot();

        assertTrue(registry.globalRoot() != bytes32(0));

        UniversalNullifierRegistry.GlobalEpochSnapshot memory snap = registry
            .getSnapshot(0);
        assertEq(snap.chainCount, 2);
    }

    // ── Nullifier Reporting ───────────────────────────

    function test_isNullifierSpentGlobally_default_false() public view {
        (bool spent, ) = registry.isNullifierSpentGlobally(keccak256("nul"));
        assertFalse(spent);
    }

    function test_reportNullifierSpent_with_single_element_tree() public {
        _setupAvaxChain();

        // Create a single-element "Merkle tree": root = leaf
        bytes32 nullifier = keccak256("spent-nullifier");

        // Submit epoch root that IS the nullifier (trivial case: 1 leaf)
        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, nullifier, 1);

        // Report with empty proof (leaf == root)
        bytes32[] memory proof = new bytes32[](0);
        uint256[] memory pathIndices = new uint256[](0);

        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            1,
            proof,
            pathIndices
        );

        (bool spent, uint256 chainId) = registry.isNullifierSpentGlobally(
            nullifier
        );
        assertTrue(spent);
        assertEq(chainId, AVAX_CHAIN_ID);
    }

    function test_reportNullifierSpent_reverts_duplicate() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul-dup");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, nullifier, 1);

        bytes32[] memory proof = new bytes32[](0);
        uint256[] memory pathIndices = new uint256[](0);

        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            1,
            proof,
            pathIndices
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.NullifierAlreadyReported.selector,
                AVAX_CHAIN_ID,
                nullifier
            )
        );
        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            1,
            proof,
            pathIndices
        );
    }

    function test_reportNullifierSpent_reverts_invalid_proof() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul-fake");
        bytes32 fakeRoot = keccak256("different-root");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, fakeRoot, 1);

        bytes32[] memory proof = new bytes32[](0);
        uint256[] memory pathIndices = new uint256[](0);

        vm.expectRevert(
            UniversalNullifierRegistry.InvalidInclusionProof.selector
        );
        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            1,
            proof,
            pathIndices
        );
    }

    function test_reportNullifierSpent_reverts_unregistered_chain() public {
        bytes32[] memory proof = new bytes32[](0);
        uint256[] memory pathIndices = new uint256[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.ChainNotRegistered.selector,
                9999
            )
        );
        registry.reportNullifierSpent(
            9999,
            keccak256("n"),
            1,
            proof,
            pathIndices
        );
    }

    // ── View Helpers ──────────────────────────────────

    function test_getRegisteredChainCount() public {
        assertEq(registry.getRegisteredChainCount(), 0);

        _setupTwoChains();
        assertEq(registry.getRegisteredChainCount(), 2);
    }

    function test_getSnapshotCount() public {
        assertEq(registry.getSnapshotCount(), 0);

        registry.createGlobalSnapshot();
        assertEq(registry.getSnapshotCount(), 1);
    }
}
