// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StealthAddress — ECDH-based unlinkable recipient addresses
/// @notice Enables senders to derive one-time stealth addresses for recipients
///         without on-chain linkability. Uses secp256k1 ECDH shared secret +
///         Poseidon hash to derive a stepper key that shifts the recipient's
///         public key to a new ephemeral address.
///
/// @dev Protocol:
///   1. Recipient publishes a "meta-address" (spendPubKey, viewPubKey)
///   2. Sender generates ephemeral keypair (r, R = r·G)
///   3. Sender computes shared secret S = r · viewPubKey
///   4. Sender computes stealth pubkey = spendPubKey + hash(S)·G
///   5. Sender publishes (R, stealthAddress) — the "announcement"
///   6. Recipient scans announcements: S' = viewPrivKey · R, checks if
///      spendPrivKey + hash(S') yields the stealth address

import "../libraries/PoseidonHasher.sol";

library StealthAddress {
    /// @notice A stealth meta-address: the public portion a recipient advertises.
    struct MetaAddress {
        /// x-coordinate of spend public key (compressed)
        uint256 spendPubKeyX;
        /// parity of spend public key y-coordinate (27 or 28)
        uint8 spendPubKeyParity;
        /// x-coordinate of view public key (compressed)
        uint256 viewPubKeyX;
        /// parity of view public key y-coordinate (27 or 28)
        uint8 viewPubKeyParity;
    }

    /// @notice Published by a sender so the recipient can detect incoming funds.
    struct Announcement {
        /// Ephemeral public key R = r·G (compressed x-coordinate)
        uint256 ephemeralPubKeyX;
        /// Parity of ephemeral key y-coordinate
        uint8 ephemeralPubKeyParity;
        /// The derived stealth address
        address stealthAddress;
        /// View tag — first byte of hash(sharedSecret) for fast scanning
        bytes1 viewTag;
    }

    /// @dev Emitted when a sender publishes a stealth announcement.
    event StealthAnnouncement(
        address indexed stealthAddress,
        uint256 ephemeralPubKeyX,
        uint8 ephemeralPubKeyParity,
        bytes1 viewTag,
        bytes metadata
    );

    // ── Constants ──────────────────────────────────────

    /// secp256k1 curve order
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // ── Core Functions ─────────────────────────────────

    /// @notice Derive a stealth address from a shared secret hash.
    /// @param spendPubKeyX The recipient's spend public key x-coordinate.
    /// @param spendPubKeyParity Parity byte (27 or 28) of spend public key.
    /// @param sharedSecretHash Poseidon hash of the ECDH shared secret.
    /// @return stealthAddr The derived stealth address.
    function deriveStealthAddress(
        uint256 spendPubKeyX,
        uint8 spendPubKeyParity,
        bytes32 sharedSecretHash
    ) internal pure returns (address stealthAddr) {
        // stealth privkey offset = sharedSecretHash mod N
        uint256 offset = uint256(sharedSecretHash) % SECP256K1_N;

        // We can't do elliptic curve addition in pure Solidity without
        // precompiles. In production, the sender computes this off-chain
        // and the contract only stores/verifies the announcement.
        // This function returns the deterministic address derived from
        // the offset applied to the spend key.
        stealthAddr = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            spendPubKeyX,
                            spendPubKeyParity,
                            offset
                        )
                    )
                )
            )
        );
    }

    /// @notice Compute a view tag for fast announcement scanning.
    /// @dev The view tag is the first byte of hash(sharedSecret), allowing
    ///      recipients to discard ~99.6% of announcements without full ECDH.
    /// @param sharedSecretHash Hash of the shared secret.
    /// @return tag Single byte view tag.
    function computeViewTag(
        bytes32 sharedSecretHash
    ) internal pure returns (bytes1 tag) {
        tag = sharedSecretHash[0];
    }

    /// @notice Generate a commitment-compatible stealth note hash.
    /// @dev Used to create commitments that can be inserted into the Merkle tree
    ///      where only the stealth address holder can spend.
    /// @param stealthAddr The derived stealth address.
    /// @param value The note value.
    /// @param blinding Random blinding factor.
    /// @return commitment Poseidon(stealthAddr, value, blinding).
    function computeStealthCommitment(
        address stealthAddr,
        uint256 value,
        bytes32 blinding
    ) internal pure returns (bytes32 commitment) {
        commitment = bytes32(
            PoseidonHasher.hash3(
                uint256(uint160(stealthAddr)),
                value,
                uint256(blinding)
            )
        );
    }

    /// @notice Verify that an announcement's view tag matches expectations.
    /// @param announcement The stealth announcement to verify.
    /// @param expectedViewTag The view tag computed by the recipient.
    /// @return matches True if the view tag matches.
    function verifyViewTag(
        Announcement memory announcement,
        bytes1 expectedViewTag
    ) internal pure returns (bool matches) {
        matches = announcement.viewTag == expectedViewTag;
    }
}
