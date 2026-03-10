// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/StealthAddress.sol";

/// @title StealthAnnouncer — On-chain stealth address announcement registry
/// @notice Senders publish stealth announcements here so recipients can scan
///         for incoming private payments. Uses view tags for efficient scanning.
contract StealthAnnouncer {
    using StealthAddress for *;

    // ── Storage ────────────────────────────────────────

    /// @notice All announcements, append-only.
    StealthAddress.Announcement[] public announcements;

    /// @notice Registered meta-addresses (recipient → MetaAddress).
    mapping(address => StealthAddress.MetaAddress) public metaAddresses;

    /// @notice Whether an address has registered a meta-address.
    mapping(address => bool) public hasMetaAddress;

    /// @notice Index of the latest announcement per stealth address.
    mapping(address => uint256) public latestAnnouncementIndex;

    // ── Events ─────────────────────────────────────────

    event MetaAddressRegistered(
        address indexed registrant,
        uint256 spendPubKeyX,
        uint256 viewPubKeyX
    );

    event AnnouncementPublished(
        uint256 indexed index,
        address indexed stealthAddress,
        uint256 ephemeralPubKeyX,
        bytes1 viewTag
    );

    // ── Meta-Address Registration ──────────────────────

    /// @notice Register or update your stealth meta-address.
    /// @param spendPubKeyX x-coordinate of your spend public key.
    /// @param spendPubKeyParity Parity byte (27 or 28).
    /// @param viewPubKeyX x-coordinate of your view public key.
    /// @param viewPubKeyParity Parity byte (27 or 28).
    function registerMetaAddress(
        uint256 spendPubKeyX,
        uint8 spendPubKeyParity,
        uint256 viewPubKeyX,
        uint8 viewPubKeyParity
    ) external {
        require(
            spendPubKeyParity == 27 || spendPubKeyParity == 28,
            "Invalid spend parity"
        );
        require(
            viewPubKeyParity == 27 || viewPubKeyParity == 28,
            "Invalid view parity"
        );

        metaAddresses[msg.sender] = StealthAddress.MetaAddress({
            spendPubKeyX: spendPubKeyX,
            spendPubKeyParity: spendPubKeyParity,
            viewPubKeyX: viewPubKeyX,
            viewPubKeyParity: viewPubKeyParity
        });
        hasMetaAddress[msg.sender] = true;

        emit MetaAddressRegistered(msg.sender, spendPubKeyX, viewPubKeyX);
    }

    // ── Announcement Publishing ────────────────────────

    /// @notice Publish a stealth announcement (sender-side).
    /// @dev The sender generates an ephemeral key, computes the ECDH shared
    ///      secret off-chain, derives the stealth address, and publishes them here.
    /// @param ephemeralPubKeyX x-coordinate of the ephemeral public key R.
    /// @param ephemeralPubKeyParity Parity byte.
    /// @param stealthAddr The derived stealth address.
    /// @param viewTag First byte of hash(sharedSecret) for fast scanning.
    /// @param metadata Optional encrypted metadata (e.g., value hint).
    function publishAnnouncement(
        uint256 ephemeralPubKeyX,
        uint8 ephemeralPubKeyParity,
        address stealthAddr,
        bytes1 viewTag,
        bytes calldata metadata
    ) external {
        StealthAddress.Announcement memory ann = StealthAddress.Announcement({
            ephemeralPubKeyX: ephemeralPubKeyX,
            ephemeralPubKeyParity: ephemeralPubKeyParity,
            stealthAddress: stealthAddr,
            viewTag: viewTag
        });

        uint256 idx = announcements.length;
        announcements.push(ann);
        latestAnnouncementIndex[stealthAddr] = idx;

        emit AnnouncementPublished(idx, stealthAddr, ephemeralPubKeyX, viewTag);
        emit StealthAddress.StealthAnnouncement(
            stealthAddr,
            ephemeralPubKeyX,
            ephemeralPubKeyParity,
            viewTag,
            metadata
        );
    }

    // ── Queries ────────────────────────────────────────

    /// @notice Get total number of announcements.
    function getAnnouncementCount() external view returns (uint256) {
        return announcements.length;
    }

    /// @notice Get announcements in a range (for scanning).
    /// @param fromIndex Start index (inclusive).
    /// @param count Number of announcements to return.
    function getAnnouncements(
        uint256 fromIndex,
        uint256 count
    ) external view returns (StealthAddress.Announcement[] memory result) {
        uint256 end = fromIndex + count;
        if (end > announcements.length) {
            end = announcements.length;
        }
        uint256 len = end - fromIndex;
        result = new StealthAddress.Announcement[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = announcements[fromIndex + i];
        }
    }

    /// @notice Get a recipient's registered meta-address.
    function getMetaAddress(
        address recipient
    ) external view returns (StealthAddress.MetaAddress memory) {
        require(hasMetaAddress[recipient], "No meta-address registered");
        return metaAddresses[recipient];
    }
}
