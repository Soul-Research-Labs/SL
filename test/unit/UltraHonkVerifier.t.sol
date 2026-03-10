// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UltraHonkVerifier} from "../../contracts/verifiers/UltraHonkVerifier.sol";

contract UltraHonkVerifierUnitTest is Test {
    UltraHonkVerifier verifier;
    address governance;

    function setUp() public {
        governance = address(this);
        verifier = new UltraHonkVerifier(governance);
    }

    // ── Proving System ─────────────────────────────────

    function test_provingSystem() public view {
        assertEq(verifier.provingSystem(), "UltraHonk");
    }

    // ── Proof Validation ───────────────────────────────

    function test_rejectEmptyProof() public view {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        assertFalse(verifier.verifyTransferProof("", inputs));
    }

    function test_rejectTooShortProof() public view {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        bytes memory shortProof = new bytes(64);
        assertFalse(verifier.verifyTransferProof(shortProof, inputs));
    }

    function test_rejectMisalignedProof() public view {
        uint256[] memory inputs = new uint256[](1);
        inputs[0] = 1;
        // 769 bytes — not 32-byte aligned
        bytes memory proof = new bytes(769);
        proof[0] = 0x01;
        assertFalse(verifier.verifyTransferProof(proof, inputs));
    }

    function test_rejectEmptyPublicInputs() public view {
        bytes memory proof = _minimalProof();
        uint256[] memory inputs = new uint256[](0);
        assertFalse(verifier.verifyTransferProof(proof, inputs));
    }

    // ── VK Immutability ────────────────────────────────

    function test_VKAlreadyInitialized() public {
        UltraHonkVerifier.HonkVerificationKey memory vk = _dummyVK();
        verifier.setTransferVK(vk);
        vm.expectRevert();
        verifier.setTransferVK(vk);
    }

    // ── Governance ─────────────────────────────────────

    function test_onlyGovernanceCanSetVK() public {
        UltraHonkVerifier.HonkVerificationKey memory vk = _dummyVK();
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        verifier.setTransferVK(vk);
    }

    function test_setGovernance() public {
        address newGov = address(0xBEEF);
        verifier.setGovernance(newGov);
        assertEq(verifier.governance(), newGov);
    }

    // ── Helpers ────────────────────────────────────────

    function _minimalProof() internal pure returns (bytes memory) {
        // 768 bytes = 24 field elements — minimum valid proof
        bytes memory proof = new bytes(768);
        proof[0] = 0x01; // non-zero
        return proof;
    }

    function _dummyVK()
        internal
        pure
        returns (UltraHonkVerifier.HonkVerificationKey memory vk)
    {
        vk.circuitSize = 1024;
        vk.numPublicInputs = 5;
        vk.initialized = true;
    }
}
