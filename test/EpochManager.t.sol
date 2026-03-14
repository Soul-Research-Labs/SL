// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/libraries/PoseidonHasher.sol";

contract EpochManagerTest is Test {
    EpochManager public em;

    address public deployer = address(1);
    address public pool = address(2);
    address public bridge = address(3);
    address public alice = address(4);

    uint256 constant EPOCH_DURATION = 100;
    uint256 constant DOMAIN_CHAIN_ID = 43113;

    function setUp() public {
        vm.startPrank(deployer);
        em = new EpochManager(EPOCH_DURATION, DOMAIN_CHAIN_ID);
        em.authorizePool(pool);
        em.authorizeBridge(bridge);
        vm.stopPrank();
    }

    // ── Constructor ────────────────────────────────────

    function test_constructor_initializes_epoch_zero() public view {
        assertEq(em.currentEpochId(), 0);
        assertEq(em.epochDuration(), EPOCH_DURATION);
        assertEq(em.domainChainId(), DOMAIN_CHAIN_ID);
        assertEq(em.governance(), deployer);
    }

    function test_epoch_zero_has_correct_times() public view {
        (uint256 startTime, uint256 endTime, , , bool finalized) = em.epochs(0);
        assertEq(startTime, 1); // default block.timestamp in forge
        assertEq(endTime, 1 + EPOCH_DURATION);
        assertFalse(finalized);
    }

    // ── Nullifier Registration ─────────────────────────

    function test_registerNullifier_from_authorized_pool() public {
        bytes32 nul = keccak256("nullifier1");

        vm.prank(pool);
        em.registerNullifier(nul);

        assertTrue(em.localNullifiers(nul));
        assertEq(em.getEpochNullifierCount(0), 1);
    }

    function test_registerNullifier_reverts_unauthorized() public {
        bytes32 nul = keccak256("nullifier1");

        vm.prank(alice);
        vm.expectRevert(EpochManager.Unauthorized.selector);
        em.registerNullifier(nul);
    }

    function test_registerNullifier_multiple() public {
        vm.startPrank(pool);
        em.registerNullifier(keccak256("n1"));
        em.registerNullifier(keccak256("n2"));
        em.registerNullifier(keccak256("n3"));
        vm.stopPrank();

        assertEq(em.getEpochNullifierCount(0), 3);
    }

    // ── Epoch Lifecycle ────────────────────────────────

    function test_startNewEpoch_after_duration() public {
        // Warp past epoch end
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        em.startNewEpoch();

        assertEq(em.currentEpochId(), 1);
    }

    function test_startNewEpoch_reverts_before_duration() public {
        vm.expectRevert(EpochManager.EpochNotReady.selector);
        em.startNewEpoch();
    }

    function test_startNewEpoch_auto_finalizes_current() public {
        vm.prank(pool);
        em.registerNullifier(keccak256("n1"));

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        em.startNewEpoch();

        // Epoch 0 should be finalized
        (, , , , bool finalized) = em.epochs(0);
        assertTrue(finalized);
        // Root should be non-zero since there was 1 nullifier
        bytes32 root = em.getEpochRoot(0);
        assertTrue(root != bytes32(0));
    }

    function test_finalizeEpoch_directly() public {
        vm.prank(pool);
        em.registerNullifier(keccak256("n1"));

        em.finalizeEpoch();

        (, , , , bool finalized) = em.epochs(0);
        assertTrue(finalized);
    }

    function test_finalizeEpoch_reverts_if_already_finalized() public {
        em.finalizeEpoch();

        vm.expectRevert(EpochManager.EpochAlreadyFinalized.selector);
        em.finalizeEpoch();
    }

    function test_epoch_root_empty_when_no_nullifiers() public {
        em.finalizeEpoch();

        bytes32 root = em.getEpochRoot(0);
        assertEq(root, bytes32(0));
    }

    function test_epoch_root_single_nullifier() public {
        bytes32 nul = keccak256("only-nullifier");

        vm.prank(pool);
        em.registerNullifier(nul);

        em.finalizeEpoch();

        // With 1 nullifier, root == nullifier itself
        assertEq(em.getEpochRoot(0), nul);
    }

    function test_multiple_epochs_sequential() public {
        // Epoch 0: register nullifiers + finalize
        vm.prank(pool);
        em.registerNullifier(keccak256("e0_n1"));

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        em.startNewEpoch();
        assertEq(em.currentEpochId(), 1);

        // Epoch 1: register + finalize
        vm.prank(pool);
        em.registerNullifier(keccak256("e1_n1"));

        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        em.startNewEpoch();
        assertEq(em.currentEpochId(), 2);

        // Both epoch roots should be set
        assertTrue(em.getEpochRoot(0) != bytes32(0));
        assertTrue(em.getEpochRoot(1) != bytes32(0));
    }

    // ── Cross-Chain Sync ───────────────────────────────

    function test_receiveRemoteEpochRoot() public {
        bytes32 remoteRoot = keccak256("remote-root");

        vm.prank(bridge);
        em.receiveRemoteEpochRoot(1284, 5, remoteRoot); // Moonbeam chain ID

        assertEq(em.getRemoteEpochRoot(1284, 5), remoteRoot);
    }

    function test_receiveRemoteEpochRoot_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(EpochManager.Unauthorized.selector);
        em.receiveRemoteEpochRoot(1284, 5, keccak256("root"));
    }

    function test_receiveRemoteEpochRoot_reverts_zero_root() public {
        vm.prank(bridge);
        vm.expectRevert(EpochManager.InvalidRemoteRoot.selector);
        em.receiveRemoteEpochRoot(1284, 5, bytes32(0));
    }

    // ── Global Nullifier Check ─────────────────────────

    function test_isNullifierSpentGlobal() public {
        bytes32 nul = keccak256("tracked-nul");

        assertFalse(em.isNullifierSpentGlobal(nul));

        vm.prank(pool);
        em.registerNullifier(nul);

        assertTrue(em.isNullifierSpentGlobal(nul));
    }

    // ── Governance ─────────────────────────────────────

    function test_authorizePool() public {
        address newPool = address(100);

        vm.prank(deployer);
        em.authorizePool(newPool);

        assertTrue(em.authorizedPools(newPool));
    }

    function test_revokePool() public {
        vm.prank(deployer);
        em.revokePool(pool);

        assertFalse(em.authorizedPools(pool));

        // Should now revert on registerNullifier
        vm.prank(pool);
        vm.expectRevert(EpochManager.Unauthorized.selector);
        em.registerNullifier(keccak256("nul"));
    }

    function test_authorizeBridge() public {
        address newBridge = address(200);

        vm.prank(deployer);
        em.authorizeBridge(newBridge);

        assertTrue(em.authorizedBridges(newBridge));
    }

    function test_revokeBridge() public {
        vm.prank(deployer);
        em.revokeBridge(bridge);

        assertFalse(em.authorizedBridges(bridge));
    }

    function test_setGovernance() public {
        vm.prank(deployer);
        em.setGovernance(alice);

        assertEq(em.governance(), alice);

        // Old governance should no longer work
        vm.prank(deployer);
        vm.expectRevert(EpochManager.Unauthorized.selector);
        em.authorizePool(address(300));
    }

    function test_governance_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(EpochManager.Unauthorized.selector);
        em.authorizePool(address(300));
    }

    // ── View Helpers ───────────────────────────────────

    function test_getCurrentEpochId() public view {
        assertEq(em.getCurrentEpochId(), 0);
    }

    function test_getEpochNullifierCount_zero() public view {
        assertEq(em.getEpochNullifierCount(0), 0);
    }

    // ── Binary Merkle Tree Root Tests ──────────────────

    function test_epoch_root_two_nullifiers_is_binary_tree() public {
        bytes32 n1 = keccak256("null-a");
        bytes32 n2 = keccak256("null-b");

        vm.startPrank(pool);
        em.registerNullifier(n1);
        em.registerNullifier(n2);
        vm.stopPrank();

        em.finalizeEpoch();

        // Binary Merkle tree of 2 leaves: root = Poseidon(n1, n2)
        bytes32 expected = bytes32(
            PoseidonHasher.hash(uint256(n1), uint256(n2))
        );
        assertEq(em.getEpochRoot(0), expected);
    }

    function test_epoch_root_three_nullifiers_padded_tree() public {
        bytes32 n1 = keccak256("null-1");
        bytes32 n2 = keccak256("null-2");
        bytes32 n3 = keccak256("null-3");

        vm.startPrank(pool);
        em.registerNullifier(n1);
        em.registerNullifier(n2);
        em.registerNullifier(n3);
        vm.stopPrank();

        em.finalizeEpoch();

        // 3 nullifiers → padded to 4 leaves: [n1, n2, n3, 0]
        // Layer 1: [Poseidon(n1,n2), Poseidon(n3,0)]
        // Layer 2: Poseidon(Layer1[0], Layer1[1])
        bytes32 left = bytes32(PoseidonHasher.hash(uint256(n1), uint256(n2)));
        bytes32 right = bytes32(PoseidonHasher.hash(uint256(n3), 0));
        bytes32 expected = bytes32(
            PoseidonHasher.hash(uint256(left), uint256(right))
        );
        assertEq(em.getEpochRoot(0), expected);
    }

    function test_epoch_root_four_nullifiers() public {
        bytes32 n1 = keccak256("a");
        bytes32 n2 = keccak256("b");
        bytes32 n3 = keccak256("c");
        bytes32 n4 = keccak256("d");

        vm.startPrank(pool);
        em.registerNullifier(n1);
        em.registerNullifier(n2);
        em.registerNullifier(n3);
        em.registerNullifier(n4);
        vm.stopPrank();

        em.finalizeEpoch();

        bytes32 left = bytes32(PoseidonHasher.hash(uint256(n1), uint256(n2)));
        bytes32 right = bytes32(PoseidonHasher.hash(uint256(n3), uint256(n4)));
        bytes32 expected = bytes32(
            PoseidonHasher.hash(uint256(left), uint256(right))
        );
        assertEq(em.getEpochRoot(0), expected);
    }

    function test_epoch_root_deterministic_different_order() public {
        // Verify that the same nullifiers in different order produce different roots
        // (tree is position-dependent, not a set hash)
        EpochManager em2 = new EpochManager(EPOCH_DURATION, DOMAIN_CHAIN_ID);
        em2.authorizePool(pool);

        bytes32 n1 = keccak256("x");
        bytes32 n2 = keccak256("y");

        vm.startPrank(pool);
        em.registerNullifier(n1);
        em.registerNullifier(n2);
        em2.registerNullifier(n2);
        em2.registerNullifier(n1);
        vm.stopPrank();

        em.finalizeEpoch();
        em2.finalizeEpoch();

        // Different order should produce different roots
        assertTrue(em.getEpochRoot(0) != em2.getEpochRoot(0));
    }
}
