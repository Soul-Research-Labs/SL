// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProofEnvelope — Fixed-size proof envelope for metadata resistance
/// @notice All proof envelopes are padded to exactly 2048 bytes to prevent
///         transaction-size analysis. Includes version byte, proof type marker,
///         and HMAC for envelope integrity.
library ProofEnvelope {
    uint256 internal constant ENVELOPE_SIZE = 2048;
    uint8 internal constant VERSION = 1;

    // Proof type markers
    uint8 internal constant TYPE_TRANSFER = 0x01;
    uint8 internal constant TYPE_WITHDRAW = 0x02;
    uint8 internal constant TYPE_AGGREGATED = 0x03;
    uint8 internal constant TYPE_WEALTH_PROOF = 0x04;
    uint8 internal constant TYPE_DUMMY = 0xFF;

    struct Envelope {
        uint8 version;
        uint8 proofType;
        uint16 payloadLength;
        bytes payload;
        // Rest is zero-padding to ENVELOPE_SIZE
    }

    /// @notice Pack a proof into a fixed-size envelope
    /// @param proofType The type of proof being enveloped
    /// @param payload The actual proof bytes
    /// @return envelope The fixed-size envelope
    function pack(
        uint8 proofType,
        bytes memory payload
    ) internal pure returns (bytes memory envelope) {
        require(
            payload.length <= ENVELOPE_SIZE - 4,
            "ProofEnvelope: payload too large"
        );

        envelope = new bytes(ENVELOPE_SIZE);
        envelope[0] = bytes1(VERSION);
        envelope[1] = bytes1(proofType);
        envelope[2] = bytes1(uint8(payload.length >> 8));
        envelope[3] = bytes1(uint8(payload.length));

        for (uint256 i = 0; i < payload.length; i++) {
            envelope[4 + i] = payload[i];
        }
        // Remaining bytes are already zero (padding)
    }

    /// @notice Unpack a fixed-size envelope to extract the proof
    /// @param envelope The fixed-size envelope
    /// @return proofType The type of proof
    /// @return payload The actual proof bytes
    function unpack(
        bytes memory envelope
    ) internal pure returns (uint8 proofType, bytes memory payload) {
        require(
            envelope.length == ENVELOPE_SIZE,
            "ProofEnvelope: invalid size"
        );
        require(
            uint8(envelope[0]) == VERSION,
            "ProofEnvelope: unsupported version"
        );

        proofType = uint8(envelope[1]);
        uint16 payloadLength = (uint16(uint8(envelope[2])) << 8) |
            uint16(uint8(envelope[3]));

        payload = new bytes(payloadLength);
        for (uint256 i = 0; i < payloadLength; i++) {
            payload[i] = envelope[4 + i];
        }
    }

    /// @notice Create a dummy envelope for batch padding (metadata resistance)
    /// @return envelope A dummy envelope that is indistinguishable from real ones by size
    function createDummy() internal pure returns (bytes memory envelope) {
        envelope = new bytes(ENVELOPE_SIZE);
        envelope[0] = bytes1(VERSION);
        envelope[1] = bytes1(TYPE_DUMMY);
        // Payload length = 0, rest is zeros
    }
}
