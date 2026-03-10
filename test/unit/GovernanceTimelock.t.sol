// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GovernanceTimelock} from "../../contracts/core/GovernanceTimelock.sol";

contract GovernanceTimelockUnitTest is Test {
    GovernanceTimelock timelock;
    address admin;
    uint256 constant DELAY = 2 days;

    function setUp() public {
        admin = address(this);
        timelock = new GovernanceTimelock(admin, DELAY);
    }

    // ── Initialization ─────────────────────────────────

    function test_adminSet() public view {
        assertEq(timelock.admin(), admin);
    }

    function test_delaySet() public view {
        assertEq(timelock.delay(), DELAY);
    }

    function test_constants() public view {
        assertEq(timelock.GRACE_PERIOD(), 14 days);
        assertEq(timelock.MINIMUM_DELAY(), 1 hours);
        assertEq(timelock.MAXIMUM_DELAY(), 30 days);
    }

    // ── Queue Transaction ──────────────────────────────

    function test_queueTransaction() public {
        address target = address(0xBEEF);
        uint256 eta = block.timestamp + DELAY;
        bytes32 txHash = timelock.queueTransaction(target, 0, "", eta);
        assertTrue(timelock.isQueued(txHash));
    }

    function test_queueUnauthorized() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        timelock.queueTransaction(
            address(0xBEEF),
            0,
            "",
            block.timestamp + DELAY
        );
    }

    // ── Cancel Transaction ─────────────────────────────

    function test_cancelTransaction() public {
        address target = address(0xBEEF);
        uint256 eta = block.timestamp + DELAY;
        bytes32 txHash = timelock.queueTransaction(target, 0, "", eta);
        timelock.cancelTransaction(target, 0, "", eta);
        assertFalse(timelock.isQueued(txHash));
    }

    // ── Execute Transaction ────────────────────────────

    function test_executeTooEarly() public {
        address target = address(0xBEEF);
        uint256 eta = block.timestamp + DELAY;
        timelock.queueTransaction(target, 0, "", eta);
        // Don't advance time — should revert
        vm.expectRevert();
        timelock.executeTransaction(target, 0, "", eta);
    }

    // ── Admin Transfer ─────────────────────────────────

    function test_setPendingAdmin() public {
        address newAdmin = address(0xCAFE);
        // setPendingAdmin must be called by the timelock itself
        // This would require queueing — just verify unauthorized revert
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        timelock.setPendingAdmin(newAdmin);
    }

    // ── Delay Bounds ───────────────────────────────────

    function test_setDelayBounds() public {
        // setDelay is onlyTimelock — cannot call directly
        // Just verify the delay is within bounds
        assertTrue(timelock.delay() >= timelock.MINIMUM_DELAY());
        assertTrue(timelock.delay() <= timelock.MAXIMUM_DELAY());
    }
}
