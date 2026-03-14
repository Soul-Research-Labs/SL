// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/libraries/ProofEnvelope.sol";

contract ProofEnvelopeTest is Test {
    using ProofEnvelope for *;

    // ── Pack / Unpack round-trip ────────────────────────────────────

    function test_pack_unpack_roundtrip() public pure {
        bytes memory payload = hex"deadbeef";
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            payload
        );

        (uint8 proofType, bytes memory decoded) = ProofEnvelope.unpack(
            envelope
        );
        assertEq(proofType, ProofEnvelope.TYPE_TRANSFER);
        assertEq(keccak256(decoded), keccak256(payload));
    }

    function test_pack_produces_fixed_size() public pure {
        bytes memory small = hex"01";
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_WITHDRAW,
            small
        );
        assertEq(envelope.length, ProofEnvelope.ENVELOPE_SIZE);
    }

    function test_pack_empty_payload() public pure {
        bytes memory empty = "";
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_AGGREGATED,
            empty
        );
        assertEq(envelope.length, ProofEnvelope.ENVELOPE_SIZE);

        (uint8 proofType, bytes memory decoded) = ProofEnvelope.unpack(
            envelope
        );
        assertEq(proofType, ProofEnvelope.TYPE_AGGREGATED);
        assertEq(decoded.length, 0);
    }

    function test_pack_maximum_payload() public pure {
        // Maximum payload = ENVELOPE_SIZE - 4 header bytes
        bytes memory maxPayload = new bytes(ProofEnvelope.ENVELOPE_SIZE - 4);
        for (uint256 i = 0; i < maxPayload.length; i++) {
            maxPayload[i] = bytes1(uint8(i & 0xFF));
        }

        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            maxPayload
        );
        assertEq(envelope.length, ProofEnvelope.ENVELOPE_SIZE);

        (, bytes memory decoded) = ProofEnvelope.unpack(envelope);
        assertEq(keccak256(decoded), keccak256(maxPayload));
    }

    // ── Header encoding ────────────────────────────────────────────

    function test_version_byte() public pure {
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            hex"abcd"
        );
        assertEq(uint8(envelope[0]), ProofEnvelope.VERSION);
    }

    function test_proof_type_byte() public pure {
        bytes memory e1 = ProofEnvelope.pack(ProofEnvelope.TYPE_TRANSFER, "");
        bytes memory e2 = ProofEnvelope.pack(ProofEnvelope.TYPE_WITHDRAW, "");
        bytes memory e3 = ProofEnvelope.pack(
            ProofEnvelope.TYPE_WEALTH_PROOF,
            ""
        );

        assertEq(uint8(e1[1]), ProofEnvelope.TYPE_TRANSFER);
        assertEq(uint8(e2[1]), ProofEnvelope.TYPE_WITHDRAW);
        assertEq(uint8(e3[1]), ProofEnvelope.TYPE_WEALTH_PROOF);
    }

    function test_payload_length_encoding() public pure {
        bytes memory payload = new bytes(300);
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            payload
        );
        // Length 300 = 0x012C → high byte = 1, low byte = 0x2C
        assertEq(uint8(envelope[2]), 1);
        assertEq(uint8(envelope[3]), 0x2C);
    }

    // ── Dummy envelopes ────────────────────────────────────────────

    function test_createDummy_fixed_size() public pure {
        bytes memory dummy = ProofEnvelope.createDummy();
        assertEq(dummy.length, ProofEnvelope.ENVELOPE_SIZE);
    }

    function test_createDummy_type_marker() public pure {
        bytes memory dummy = ProofEnvelope.createDummy();
        assertEq(uint8(dummy[0]), ProofEnvelope.VERSION);
        assertEq(uint8(dummy[1]), ProofEnvelope.TYPE_DUMMY);
    }

    function test_dummy_unpack_empty_payload() public pure {
        bytes memory dummy = ProofEnvelope.createDummy();
        (uint8 proofType, bytes memory payload) = ProofEnvelope.unpack(dummy);
        assertEq(proofType, ProofEnvelope.TYPE_DUMMY);
        assertEq(payload.length, 0);
    }

    function test_dummy_and_real_same_size() public pure {
        bytes memory dummy = ProofEnvelope.createDummy();
        bytes memory real = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            hex"deadbeefcafe"
        );
        assertEq(dummy.length, real.length);
    }

    // ── Error conditions ───────────────────────────────────────────

    function test_pack_reverts_payload_too_large() public {
        bytes memory oversized = new bytes(ProofEnvelope.ENVELOPE_SIZE - 3);
        vm.expectRevert("ProofEnvelope: payload too large");
        ProofEnvelope.pack(ProofEnvelope.TYPE_TRANSFER, oversized);
    }

    function test_unpack_reverts_wrong_size() public {
        bytes memory bad = new bytes(100);
        bad[0] = bytes1(ProofEnvelope.VERSION);
        vm.expectRevert("ProofEnvelope: invalid size");
        ProofEnvelope.unpack(bad);
    }

    function test_unpack_reverts_wrong_version() public {
        bytes memory bad = new bytes(ProofEnvelope.ENVELOPE_SIZE);
        bad[0] = bytes1(uint8(99)); // wrong version
        vm.expectRevert("ProofEnvelope: unsupported version");
        ProofEnvelope.unpack(bad);
    }

    // ── All proof type markers ─────────────────────────────────────

    function test_all_proof_types_roundtrip() public pure {
        uint8[5] memory types = [
            ProofEnvelope.TYPE_TRANSFER,
            ProofEnvelope.TYPE_WITHDRAW,
            ProofEnvelope.TYPE_AGGREGATED,
            ProofEnvelope.TYPE_WEALTH_PROOF,
            ProofEnvelope.TYPE_DUMMY
        ];

        for (uint256 i = 0; i < types.length; i++) {
            bytes memory env = ProofEnvelope.pack(types[i], hex"cafe");
            (uint8 pt, bytes memory pl) = ProofEnvelope.unpack(env);
            assertEq(pt, types[i]);
            assertEq(pl.length, 2);
        }
    }

    // ── Padding is zeroed ──────────────────────────────────────────

    function test_padding_is_zeroed() public pure {
        bytes memory payload = hex"ab";
        bytes memory envelope = ProofEnvelope.pack(
            ProofEnvelope.TYPE_TRANSFER,
            payload
        );
        // Check that bytes after payload (index 5 onward) are zero
        for (uint256 i = 5; i < 64 && i < ProofEnvelope.ENVELOPE_SIZE; i++) {
            assertEq(uint8(envelope[i]), 0, "Padding should be zero");
        }
    }
}
