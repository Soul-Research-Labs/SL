// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/ComplianceOracle.sol";

/// @dev Mock viewing-key verifier that always returns true.
contract MockVerifierPass {
    function verify(
        bytes calldata,
        bytes calldata
    ) external pure returns (bool) {
        return true;
    }
}

/// @dev Mock viewing-key verifier that always returns false.
contract MockVerifierFail {
    function verify(
        bytes calldata,
        bytes calldata
    ) external pure returns (bool) {
        return false;
    }
}

/// @dev Mock verifier that reverts.
contract MockVerifierRevert {
    function verify(bytes calldata, bytes calldata) external pure {
        revert("boom");
    }
}

contract ComplianceOracleTest is Test {
    ComplianceOracle public oracle;
    address public gov;

    bytes32[2] internal dummyNullifiers;
    bytes32[2] internal dummyCommitments;

    function setUp() public {
        gov = address(this);
        oracle = new ComplianceOracle();

        dummyNullifiers[0] = bytes32(uint256(1));
        dummyNullifiers[1] = bytes32(uint256(2));
        dummyCommitments[0] = bytes32(uint256(3));
        dummyCommitments[1] = bytes32(uint256(4));
    }

    // ── Initial state ──────────────────────────────────────────────

    function test_initial_state() public view {
        assertEq(oracle.governance(), gov);
        assertTrue(oracle.complianceEnabled());
        assertEq(oracle.policyVersion(), 1);
        assertEq(oracle.viewingKeyVerifier(), address(0));
        assertEq(oracle.enhancedDueDiligenceThreshold(), 0);
    }

    // ── checkCompliance basics ─────────────────────────────────────

    function test_compliance_passes_clean_tx() public view {
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            ""
        );
        assertTrue(ok);
    }

    function test_compliance_disabled_always_passes() public {
        oracle.setComplianceEnabled(false);
        // Even with blocked nullifiers, should pass when disabled
        oracle.blockCommitment(dummyNullifiers[0], "tainted");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            ""
        );
        assertTrue(ok);
    }

    // ── Blocklist ──────────────────────────────────────────────────

    function test_blockAddress() public {
        address target = address(0xBAD);
        assertFalse(oracle.isBlocked(target));

        oracle.blockAddress(target, "sanctioned");
        assertTrue(oracle.isBlocked(target));
    }

    function test_unblockAddress() public {
        address target = address(0xBAD);
        oracle.blockAddress(target, "sanctioned");
        oracle.unblockAddress(target);
        assertFalse(oracle.isBlocked(target));
    }

    function test_blockCommitment_nullifier_blocks_tx() public {
        oracle.blockCommitment(dummyNullifiers[0], "tainted");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            ""
        );
        assertFalse(ok);
    }

    function test_blockCommitment_output_blocks_tx() public {
        oracle.blockCommitment(dummyCommitments[1], "tainted");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            ""
        );
        assertFalse(ok);
    }

    function test_isCommitmentBlocked() public {
        bytes32 cm = bytes32(uint256(99));
        assertFalse(oracle.isCommitmentBlocked(cm));
        oracle.blockCommitment(cm, "reason");
        assertTrue(oracle.isCommitmentBlocked(cm));
    }

    // ── Auditor management ─────────────────────────────────────────

    function test_addAuditor() public {
        address aud = address(0xA0D);
        assertFalse(oracle.authorizedAuditors(aud));
        oracle.addAuditor(aud);
        assertTrue(oracle.authorizedAuditors(aud));
    }

    function test_removeAuditor() public {
        address aud = address(0xA0D);
        oracle.addAuditor(aud);
        oracle.removeAuditor(aud);
        assertFalse(oracle.authorizedAuditors(aud));
    }

    // ── Governance access control ──────────────────────────────────

    function test_blockAddress_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.blockAddress(address(0xBAD), "x");
    }

    function test_unblockAddress_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.unblockAddress(address(0xBAD));
    }

    function test_addAuditor_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.addAuditor(address(0xA0D));
    }

    function test_setComplianceEnabled_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.setComplianceEnabled(false);
    }

    function test_transferGovernance() public {
        address newGov = address(0xNEEEEE1);
        oracle.transferGovernance(newGov);
        assertEq(oracle.governance(), newGov);
    }

    function test_transferGovernance_rejects_zero() public {
        vm.expectRevert("ComplianceOracle: zero address");
        oracle.transferGovernance(address(0));
    }

    function test_transferGovernance_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.transferGovernance(address(0x1));
    }

    // ── Policy version ─────────────────────────────────────────────

    function test_updatePolicy_increments() public {
        assertEq(oracle.policyVersion(), 1);
        oracle.updatePolicy();
        assertEq(oracle.policyVersion(), 2);
        oracle.updatePolicy();
        assertEq(oracle.policyVersion(), 3);
    }

    function test_setEDDThreshold() public {
        oracle.setEDDThreshold(10 ether);
        assertEq(oracle.enhancedDueDiligenceThreshold(), 10 ether);
    }

    // ── Viewing-key proof verification ─────────────────────────────

    function test_nonempty_proof_no_verifier_passes() public view {
        // No verifier set → non-empty proof accepted (testnet mode)
        bytes memory proof = abi.encodePacked(bytes32(uint256(1)), hex"FF");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            proof
        );
        assertTrue(ok);
    }

    function test_viewing_key_proof_passes_with_mock_verifier() public {
        MockVerifierPass v = new MockVerifierPass();
        oracle.setViewingKeyVerifier(address(v));

        // Proof: 32-byte auditorPubKeyHash + at least 1 byte zkProof
        bytes memory proof = abi.encodePacked(bytes32(uint256(0xABC)), hex"01");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            proof
        );
        assertTrue(ok);
    }

    function test_viewing_key_proof_fails_with_failing_verifier() public {
        MockVerifierFail v = new MockVerifierFail();
        oracle.setViewingKeyVerifier(address(v));

        bytes memory proof = abi.encodePacked(bytes32(uint256(0xABC)), hex"01");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            proof
        );
        assertFalse(ok);
    }

    function test_viewing_key_proof_reverts_verifier_returns_false() public {
        MockVerifierRevert v = new MockVerifierRevert();
        oracle.setViewingKeyVerifier(address(v));

        bytes memory proof = abi.encodePacked(bytes32(uint256(0xABC)), hex"01");
        bool ok = oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            proof
        );
        assertFalse(ok);
    }

    function test_viewing_key_proof_too_short_reverts() public {
        MockVerifierPass v = new MockVerifierPass();
        oracle.setViewingKeyVerifier(address(v));

        // Less than 33 bytes with a verifier set
        bytes memory shortProof = hex"ABCD";
        vm.expectRevert("ComplianceOracle: proof too short");
        oracle.checkCompliance(
            dummyNullifiers,
            dummyCommitments,
            shortProof
        );
    }

    // ── setViewingKeyVerifier ──────────────────────────────────────

    function test_setViewingKeyVerifier() public {
        address v = address(0x123);
        oracle.setViewingKeyVerifier(v);
        assertEq(oracle.viewingKeyVerifier(), v);
    }

    function test_setViewingKeyVerifier_onlyGovernance() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.setViewingKeyVerifier(address(0x1));
    }

    // ── Events ─────────────────────────────────────────────────────

    function test_emits_AddressBlocked() public {
        vm.expectEmit(true, false, false, true);
        emit ComplianceOracle.AddressBlocked(address(0xBAD), "reason");
        oracle.blockAddress(address(0xBAD), "reason");
    }

    function test_emits_AddressUnblocked() public {
        oracle.blockAddress(address(0xBAD), "reason");
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.AddressUnblocked(address(0xBAD));
        oracle.unblockAddress(address(0xBAD));
    }

    function test_emits_AuditorAdded() public {
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.AuditorAdded(address(0xA0D));
        oracle.addAuditor(address(0xA0D));
    }

    function test_emits_PolicyUpdated() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceOracle.PolicyUpdated(2);
        oracle.updatePolicy();
    }

    function test_emits_ComplianceToggled() public {
        vm.expectEmit(false, false, false, true);
        emit ComplianceOracle.ComplianceToggled(false);
        oracle.setComplianceEnabled(false);
    }
}
