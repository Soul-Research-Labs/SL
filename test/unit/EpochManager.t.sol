// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";

contract EpochManagerUnitTest is Test {
    EpochManager em;
    address governance;
    address pool;
    address bridge;

    uint256 constant EPOCH_DURATION = 100;
    uint256 constant CHAIN_ID = 43113;

    function setUp() public {
        governance = address(this);
        pool = address(0xAA);
        bridge = address(0xBB);

        em = new EpochManager(EPOCH_DURATION, CHAIN_ID);
        em.authorizePool(pool);
        em.authorizeBridge(bridge);
    }

    // ── Authorization ──────────────────────────────────

    function test_authorizePool() public view {
        assertTrue(em.authorizedPools(pool));
    }

    function test_revokePool() public {
        em.revokePool(pool);
        assertFalse(em.authorizedPools(pool));
    }

    function test_authorizeBridge() public view {
        assertTrue(em.authorizedBridges(bridge));
    }

    function test_revokeBridge() public {
        em.revokeBridge(bridge);
        assertFalse(em.authorizedBridges(bridge));
    }

    function test_unauthorizedCannotAuthorize() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        em.authorizePool(address(0xCC));
    }

    // ── Epoch Lifecycle ────────────────────────────────

    function test_initialEpochIsZero() public view {
        assertEq(em.currentEpochId(), 0);
    }

    function test_startNewEpoch() public {
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        em.startNewEpoch();
        assertEq(em.currentEpochId(), 1);
    }

    function test_registerNullifier() public {
        bytes32 nul = keccak256("nul1");
        vm.prank(pool);
        em.registerNullifier(nul);
        assertTrue(em.isNullifierSpentGlobal(nul));
    }

    function test_registerNullifierUnauthorized() public {
        bytes32 nul = keccak256("nul1");
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        em.registerNullifier(nul);
    }

    // ── Remote Roots ───────────────────────────────────

    function test_receiveRemoteRoot() public {
        bytes32 root = keccak256("remote_root");
        vm.prank(bridge);
        em.receiveRemoteEpochRoot(1284, 0, root);
        assertEq(em.getRemoteEpochRoot(1284, 0), root);
    }

    function test_receiveRemoteRootUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        em.receiveRemoteEpochRoot(1284, 0, keccak256("x"));
    }

    // ── Governance Transfer ────────────────────────────

    function test_setGovernance() public {
        address newGov = address(0xFFFF);
        em.setGovernance(newGov);
        assertEq(em.governance(), newGov);
    }

    function test_setGovernanceUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        em.setGovernance(address(0xFFFF));
    }
}
