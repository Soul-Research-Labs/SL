// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";
import "../contracts/libraries/PoseidonHasher.sol";

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
        bytes32 root = keccak256("epoch-root-0");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 42);

        assertEq(registry.epochRoots(AVAX_CHAIN_ID, 0), root);

        (uint256 epochId, bytes32 latestRoot) = registry.getChainLatestEpoch(
            AVAX_CHAIN_ID
        );
        assertEq(epochId, 0);
        assertEq(latestRoot, root);
    }

    function test_submitEpochRoot_first_must_be_zero() public {
        _setupAvaxChain();

        vm.prank(bridgeAvax);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.InvalidEpochSequence.selector,
                AVAX_CHAIN_ID,
                0,
                5
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN_ID, 5, keccak256("r"), 10);
    }

    function test_submitEpochRoot_reverts_unauthorized() public {
        _setupAvaxChain();

        vm.prank(alice);
        vm.expectRevert(UniversalNullifierRegistry.Unauthorized.selector);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r"), 10);
    }

    function test_submitEpochRoot_reverts_duplicate() public {
        _setupAvaxChain();
        bytes32 root = keccak256("epoch-root-0");

        vm.startPrank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 42);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.InvalidEpochSequence.selector,
                AVAX_CHAIN_ID,
                1,
                0
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 42);
        vm.stopPrank();
    }

    function test_submitEpochRoot_sequential_epochs() public {
        _setupAvaxChain();

        vm.startPrank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, keccak256("r0"), 5);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 1, keccak256("r1"), 10);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 2, keccak256("r2"), 20);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 3, keccak256("r3"), 30);
        vm.stopPrank();

        (uint256 epochId, ) = registry.getChainLatestEpoch(AVAX_CHAIN_ID);
        assertEq(epochId, 3);
    }

    function test_submitEpochRoot_reverts_gap() public {
        _setupAvaxChain();

        vm.startPrank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, keccak256("r0"), 5);

        // Skipping epoch 1 should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                UniversalNullifierRegistry.InvalidEpochSequence.selector,
                AVAX_CHAIN_ID,
                1,
                3
            )
        );
        registry.submitEpochRoot(AVAX_CHAIN_ID, 3, keccak256("r3"), 10);
        vm.stopPrank();
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
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, keccak256("gov-root"), 5);

        assertEq(registry.epochRoots(AVAX_CHAIN_ID, 0), keccak256("gov-root"));
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
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, keccak256("r0"), 10);

        registry.createGlobalSnapshot();

        assertTrue(registry.globalRoot() != bytes32(0));
        assertEq(registry.getSnapshotCount(), 1);
    }

    function test_createGlobalSnapshot_multi_chain() public {
        _setupTwoChains();

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, keccak256("avax-r0"), 10);

        vm.prank(bridgeMoon);
        registry.submitEpochRoot(MOON_CHAIN_ID, 0, keccak256("moon-r0"), 20);

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

    function test_reportNullifierSpent_with_single_sibling() public {
        _setupAvaxChain();

        // Build a 2-leaf tree: root = Poseidon(leaf, sibling)
        bytes32 nullifier = keccak256("spent-nullifier");
        bytes32 sibling = keccak256("sibling-leaf");
        bytes32 root = bytes32(
            PoseidonHasher.hash(uint256(nullifier), uint256(sibling))
        );

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 2);

        // Leaf is on the left (pathIndex=0), sibling on the right
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        uint256[] memory pathIndices = new uint256[](1);
        pathIndices[0] = 0;

        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            0,
            proof,
            pathIndices
        );

        (bool spent, uint256 chainId) = registry.isNullifierSpentGlobally(
            nullifier
        );
        assertTrue(spent);
        assertEq(chainId, AVAX_CHAIN_ID);
    }

    function test_reportNullifierSpent_empty_proof_reverts() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, nullifier, 1);

        // Empty proof should now be rejected
        bytes32[] memory proof = new bytes32[](0);
        uint256[] memory pathIndices = new uint256[](0);

        vm.expectRevert(
            UniversalNullifierRegistry.InvalidInclusionProof.selector
        );
        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            0,
            proof,
            pathIndices
        );
    }

    function test_reportNullifierSpent_bad_pathIndex_reverts() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul-bad-path");
        bytes32 sibling = keccak256("sib");
        bytes32 root = bytes32(
            PoseidonHasher.hash(uint256(nullifier), uint256(sibling))
        );

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 2);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        uint256[] memory pathIndices = new uint256[](1);
        pathIndices[0] = 2; // invalid — must be 0 or 1

        vm.expectRevert(
            UniversalNullifierRegistry.InvalidInclusionProof.selector
        );
        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            0,
            proof,
            pathIndices
        );
    }

    function test_reportNullifierSpent_reverts_duplicate() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul-dup");
        bytes32 sibling = keccak256("sib-dup");
        bytes32 root = bytes32(
            PoseidonHasher.hash(uint256(nullifier), uint256(sibling))
        );

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, root, 2);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = sibling;
        uint256[] memory pathIndices = new uint256[](1);
        pathIndices[0] = 0;

        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            0,
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
            0,
            proof,
            pathIndices
        );
    }

    function test_reportNullifierSpent_reverts_invalid_proof() public {
        _setupAvaxChain();
        bytes32 nullifier = keccak256("nul-fake");
        bytes32 fakeRoot = keccak256("different-root");

        vm.prank(bridgeAvax);
        registry.submitEpochRoot(AVAX_CHAIN_ID, 0, fakeRoot, 1);

        // Non-empty proof that doesn't match
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("wrong-sibling");
        uint256[] memory pathIndices = new uint256[](1);
        pathIndices[0] = 0;

        vm.expectRevert(
            UniversalNullifierRegistry.InvalidInclusionProof.selector
        );
        registry.reportNullifierSpent(
            AVAX_CHAIN_ID,
            nullifier,
            0,
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
