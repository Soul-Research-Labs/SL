// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiSigGovernance} from "../contracts/core/MultiSigGovernance.sol";

// ── Helper contract to receive calls from the multisig ──
contract Counter {
    uint256 public value;

    function increment() external {
        value++;
    }

    function setValue(uint256 _v) external {
        value = _v;
    }

    function reverting() external pure {
        revert("always reverts");
    }

    receive() external payable {}
}

contract MultiSigGovernanceTest is Test {
    MultiSigGovernance public msig;
    Counter public counter;

    address owner1 = makeAddr("owner1");
    address owner2 = makeAddr("owner2");
    address owner3 = makeAddr("owner3");
    address nonOwner = makeAddr("nonOwner");

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        msig = new MultiSigGovernance(owners, 2); // 2-of-3
        counter = new Counter();
    }

    // ── Constructor Tests ──────────────────────────────

    function test_constructor_setsOwners() public view {
        assertEq(msig.getOwnerCount(), 3);
        assertTrue(msig.isOwner(owner1));
        assertTrue(msig.isOwner(owner2));
        assertTrue(msig.isOwner(owner3));
        assertFalse(msig.isOwner(nonOwner));
    }

    function test_constructor_setsThreshold() public view {
        assertEq(msig.threshold(), 2);
    }

    function test_constructor_getOwners() public view {
        address[] memory owners = msig.getOwners();
        assertEq(owners.length, 3);
        assertEq(owners[0], owner1);
        assertEq(owners[1], owner2);
        assertEq(owners[2], owner3);
    }

    function test_constructor_revertsOnEmptyOwners() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(MultiSigGovernance.MinimumOneOwner.selector);
        new MultiSigGovernance(empty, 1);
    }

    function test_constructor_revertsOnZeroThreshold() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        vm.expectRevert(MultiSigGovernance.InvalidThreshold.selector);
        new MultiSigGovernance(owners, 0);
    }

    function test_constructor_revertsOnThresholdTooHigh() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        vm.expectRevert(MultiSigGovernance.InvalidThreshold.selector);
        new MultiSigGovernance(owners, 3);
    }

    function test_constructor_revertsOnDuplicateOwner() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner1; // duplicate
        vm.expectRevert(MultiSigGovernance.DuplicateOwner.selector);
        new MultiSigGovernance(owners, 1);
    }

    function test_constructor_revertsOnZeroAddress() public {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = address(0);
        vm.expectRevert(MultiSigGovernance.OwnerNotFound.selector);
        new MultiSigGovernance(owners, 1);
    }

    // ── Submit Tests ───────────────────────────────────

    function test_submit_createsProposal() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        uint256 pid = msig.submitProposal(address(counter), 0, data);

        assertEq(pid, 0);
        assertEq(msig.proposalCount(), 1);
        assertEq(msig.getConfirmationCount(0), 1); // auto-confirmed
        assertTrue(msig.hasConfirmed(0, owner1));
    }

    function test_submit_nonOwnerReverts() public {
        vm.prank(nonOwner);
        vm.expectRevert(MultiSigGovernance.NotOwner.selector);
        msig.submitProposal(address(counter), 0, "");
    }

    function test_submit_incrementsProposalCount() public {
        vm.startPrank(owner1);
        msig.submitProposal(address(counter), 0, "");
        msig.submitProposal(address(counter), 0, "");
        msig.submitProposal(address(counter), 0, "");
        vm.stopPrank();
        assertEq(msig.proposalCount(), 3);
    }

    // ── Confirm Tests ──────────────────────────────────

    function test_confirm_incrementsCount() public {
        vm.prank(owner1);
        msig.submitProposal(
            address(counter),
            0,
            abi.encodeCall(Counter.increment, ())
        );

        vm.prank(owner2);
        msig.confirmProposal(0);

        assertEq(msig.getConfirmationCount(0), 2);
        assertTrue(msig.hasConfirmed(0, owner2));
    }

    function test_confirm_doubleConfirmReverts() public {
        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, "");

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.AlreadyConfirmed.selector);
        msig.confirmProposal(0);
    }

    function test_confirm_nonOwnerReverts() public {
        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, "");

        vm.prank(nonOwner);
        vm.expectRevert(MultiSigGovernance.NotOwner.selector);
        msig.confirmProposal(0);
    }

    function test_confirm_nonexistentProposalReverts() public {
        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ProposalNotFound.selector);
        msig.confirmProposal(999);
    }

    function test_confirm_executedProposalReverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);
        vm.prank(owner1);
        msig.executeProposal(0);

        vm.prank(owner3);
        vm.expectRevert(MultiSigGovernance.ProposalAlreadyExecuted.selector);
        msig.confirmProposal(0);
    }

    // ── Revoke Tests ───────────────────────────────────

    function test_revoke_decrementsCount() public {
        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, "");

        vm.prank(owner2);
        msig.confirmProposal(0);
        assertEq(msig.getConfirmationCount(0), 2);

        vm.prank(owner2);
        msig.revokeConfirmation(0);
        assertEq(msig.getConfirmationCount(0), 1);
        assertFalse(msig.hasConfirmed(0, owner2));
    }

    function test_revoke_notConfirmedReverts() public {
        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, "");

        vm.prank(owner2);
        vm.expectRevert(MultiSigGovernance.NotConfirmed.selector);
        msig.revokeConfirmation(0);
    }

    function test_revoke_executedReverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);
        vm.prank(owner1);
        msig.executeProposal(0);

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ProposalAlreadyExecuted.selector);
        msig.revokeConfirmation(0);
    }

    // ── Execute Tests ──────────────────────────────────

    function test_execute_callsTarget() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        msig.executeProposal(0);

        assertEq(counter.value(), 1);
    }

    function test_execute_insufficientConfirmationsReverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data); // only 1 confirmation

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.InsufficientConfirmations.selector);
        msig.executeProposal(0);
    }

    function test_execute_doubleExecuteReverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);
        vm.prank(owner1);
        msig.executeProposal(0);

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ProposalAlreadyExecuted.selector);
        msig.executeProposal(0);
    }

    function test_execute_revertingTargetReverts() public {
        bytes memory data = abi.encodeCall(Counter.reverting, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ExecutionFailed.selector);
        msig.executeProposal(0);
    }

    function test_execute_withValue() public {
        vm.deal(address(msig), 1 ether);

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0.5 ether, "");
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        msig.executeProposal(0);

        assertEq(address(counter).balance, 0.5 ether);
    }

    function test_isExecutable() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());

        vm.prank(owner1);
        msig.submitProposal(address(counter), 0, data);

        assertFalse(msig.isExecutable(0)); // only 1 of 2

        vm.prank(owner2);
        msig.confirmProposal(0);
        assertTrue(msig.isExecutable(0)); // 2 of 2

        vm.prank(owner1);
        msig.executeProposal(0);
        assertFalse(msig.isExecutable(0)); // executed
    }

    // ── Self-governance Tests ──────────────────────────

    function test_addOwner_viaSelfCall() public {
        address newOwner = makeAddr("newOwner");
        bytes memory data = abi.encodeCall(
            MultiSigGovernance.addOwner,
            (newOwner)
        );

        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        msig.executeProposal(0);

        assertTrue(msig.isOwner(newOwner));
        assertEq(msig.getOwnerCount(), 4);
    }

    function test_addOwner_directCallReverts() public {
        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.NotSelf.selector);
        msig.addOwner(makeAddr("new"));
    }

    function test_addOwner_duplicateReverts() public {
        bytes memory data = abi.encodeCall(
            MultiSigGovernance.addOwner,
            (owner1)
        );

        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ExecutionFailed.selector);
        msig.executeProposal(0);
    }

    function test_removeOwner_viaSelfCall() public {
        bytes memory data = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner3)
        );

        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        msig.executeProposal(0);

        assertFalse(msig.isOwner(owner3));
        assertEq(msig.getOwnerCount(), 2);
        assertEq(msig.threshold(), 2); // unchanged since 2 <= 2
    }

    function test_removeOwner_adjustsThreshold() public {
        // Remove 2 owners (one at a time) — threshold should auto-adjust
        // First remove owner3 (3→2 owners, threshold stays 2)
        bytes memory data1 = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner3)
        );
        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data1);
        vm.prank(owner2);
        msig.confirmProposal(0);
        vm.prank(owner1);
        msig.executeProposal(0);
        assertEq(msig.threshold(), 2);

        // Now remove owner2 (2→1 owners, threshold must drop to 1)
        bytes memory data2 = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner2)
        );
        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data2);
        // Only owner1 left, threshold is 2 but we need self-call...
        // Actually after removing owner3, owner1 confirms (1 of 2 needed, only owner1+owner2 remain)
        // owner2 is still around to confirm
        vm.prank(owner2);
        msig.confirmProposal(1);
        vm.prank(owner1);
        msig.executeProposal(1);

        assertEq(msig.getOwnerCount(), 1);
        assertEq(msig.threshold(), 1); // auto-adjusted
    }

    function test_removeOwner_lastOwnerReverts() public {
        // Get down to 1 owner first
        // Remove owner3
        bytes memory d1 = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner3)
        );
        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, d1);
        vm.prank(owner2);
        msig.confirmProposal(0);
        vm.prank(owner1);
        msig.executeProposal(0);

        // Remove owner2
        bytes memory d2 = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner2)
        );
        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, d2);
        vm.prank(owner2);
        msig.confirmProposal(1);
        vm.prank(owner1);
        msig.executeProposal(1);

        // Try to remove last owner — should revert
        bytes memory d3 = abi.encodeCall(
            MultiSigGovernance.removeOwner,
            (owner1)
        );
        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, d3);
        // threshold is now 1, so 1 confirmation is enough

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ExecutionFailed.selector);
        msig.executeProposal(2);
    }

    function test_changeThreshold_viaSelfCall() public {
        bytes memory data = abi.encodeCall(
            MultiSigGovernance.changeThreshold,
            (3)
        );

        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        msig.executeProposal(0);

        assertEq(msig.threshold(), 3);
    }

    function test_changeThreshold_invalidReverts() public {
        bytes memory data = abi.encodeCall(
            MultiSigGovernance.changeThreshold,
            (0)
        );

        vm.prank(owner1);
        msig.submitProposal(address(msig), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(0);

        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.ExecutionFailed.selector);
        msig.executeProposal(0);
    }

    // ── 1-of-1 edge case ──────────────────────────────

    function test_oneOfOne_works() public {
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        MultiSigGovernance solo = new MultiSigGovernance(owners, 1);

        bytes memory data = abi.encodeCall(Counter.setValue, (42));
        vm.prank(owner1);
        uint256 pid = solo.submitProposal(address(counter), 0, data);

        // Already has 1 confirmation (auto) and threshold is 1
        assertTrue(solo.isExecutable(pid));

        vm.prank(owner1);
        solo.executeProposal(pid);
        assertEq(counter.value(), 42);
    }

    // ── Receive ETH ────────────────────────────────────

    function test_receiveETH() public {
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        (bool ok, ) = address(msig).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(msig).balance, 1 ether);
    }

    // ── Threshold-per-proposal Tests ───────────────────

    function test_threshold_stored_per_proposal() public {
        // Submit proposal when threshold is 2
        bytes memory data = abi.encodeCall(Counter.increment, ());
        vm.prank(owner1);
        uint256 pid = msig.submitProposal(address(counter), 0, data);

        // Change threshold to 1 via self-call
        bytes memory changeData = abi.encodeCall(
            MultiSigGovernance.changeThreshold,
            (1)
        );
        vm.prank(owner1);
        uint256 changePid = msig.submitProposal(address(msig), 0, changeData);
        vm.prank(owner2);
        msig.confirmProposal(changePid);
        vm.prank(owner1);
        msig.executeProposal(changePid);
        assertEq(msig.threshold(), 1);

        // The old proposal (pid=0) should still require 2 confirmations
        // (its snapshot was taken at threshold=2)
        vm.prank(owner1);
        vm.expectRevert(MultiSigGovernance.InsufficientConfirmations.selector);
        msig.executeProposal(pid); // only 1 confirmation, needs 2

        // After confirming with owner2, it should work
        vm.prank(owner2);
        msig.confirmProposal(pid);
        vm.prank(owner1);
        msig.executeProposal(pid);
        assertEq(counter.value(), 1);
    }

    function test_threshold_increase_does_not_affect_old_proposals() public {
        // Submit proposal when threshold is 2
        bytes memory data = abi.encodeCall(Counter.increment, ());
        vm.prank(owner1);
        uint256 pid = msig.submitProposal(address(counter), 0, data);
        vm.prank(owner2);
        msig.confirmProposal(pid); // now has 2 confirmations

        // Increase threshold to 3 via self-call
        bytes memory changeData = abi.encodeCall(
            MultiSigGovernance.changeThreshold,
            (3)
        );
        vm.prank(owner1);
        uint256 changePid = msig.submitProposal(address(msig), 0, changeData);
        vm.prank(owner2);
        msig.confirmProposal(changePid);
        vm.prank(owner1);
        msig.executeProposal(changePid);
        assertEq(msig.threshold(), 3);

        // Old proposal should still be executable with 2 confirmations
        // because its requiredThreshold was snapshot at 2
        assertTrue(msig.isExecutable(pid));
        vm.prank(owner1);
        msig.executeProposal(pid);
        assertEq(counter.value(), 1);
    }
}
