// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/StealthAnnouncer.sol";
import "../contracts/libraries/StealthAddress.sol";

contract StealthAnnouncerTest is Test {
    StealthAnnouncer announcer;
    address alice;
    address bob;

    function setUp() public {
        announcer = new StealthAnnouncer();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // ── Meta-Address Registration ──────────────────────

    function test_registerMetaAddress() public {
        uint256 spendX = 0x1234;
        uint256 viewX = 0x5678;

        vm.prank(alice);
        announcer.registerMetaAddress(spendX, 27, viewX, 28);

        assertTrue(announcer.hasMetaAddress(alice));

        StealthAddress.MetaAddress memory meta = announcer.getMetaAddress(
            alice
        );
        assertEq(meta.spendPubKeyX, spendX);
        assertEq(meta.spendPubKeyParity, 27);
        assertEq(meta.viewPubKeyX, viewX);
        assertEq(meta.viewPubKeyParity, 28);
    }

    function test_registerMetaAddress_invalidSpendParity_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Invalid spend parity");
        announcer.registerMetaAddress(0x1234, 0, 0x5678, 27);
    }

    function test_registerMetaAddress_invalidViewParity_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Invalid view parity");
        announcer.registerMetaAddress(0x1234, 27, 0x5678, 0);
    }

    function test_registerMetaAddress_update() public {
        vm.startPrank(alice);
        announcer.registerMetaAddress(0x1111, 27, 0x2222, 28);
        announcer.registerMetaAddress(0x3333, 28, 0x4444, 27);
        vm.stopPrank();

        StealthAddress.MetaAddress memory meta = announcer.getMetaAddress(
            alice
        );
        assertEq(meta.spendPubKeyX, 0x3333);
        assertEq(meta.viewPubKeyX, 0x4444);
    }

    function test_getMetaAddress_unregistered_reverts() public {
        vm.expectRevert("No meta-address registered");
        announcer.getMetaAddress(bob);
    }

    // ── Announcement Publishing ────────────────────────

    function test_publishAnnouncement() public {
        address stealthAddr = makeAddr("stealth");

        vm.prank(alice);
        announcer.publishAnnouncement(
            0xAAAA, // ephemeralPubKeyX
            27, // parity
            stealthAddr,
            bytes1(0xAB), // viewTag
            "" // no metadata
        );

        assertEq(announcer.getAnnouncementCount(), 1);
        assertEq(announcer.latestAnnouncementIndex(stealthAddr), 0);

        (uint256 ephX, uint8 ephParity, address sAddr, bytes1 vTag) = announcer
            .announcements(0);

        assertEq(ephX, 0xAAAA);
        assertEq(ephParity, 27);
        assertEq(sAddr, stealthAddr);
        assertEq(vTag, bytes1(0xAB));
    }

    function test_publishMultipleAnnouncements() public {
        address stealth1 = makeAddr("s1");
        address stealth2 = makeAddr("s2");

        vm.prank(alice);
        announcer.publishAnnouncement(0x01, 27, stealth1, bytes1(0x01), "");

        vm.prank(bob);
        announcer.publishAnnouncement(0x02, 28, stealth2, bytes1(0x02), "");

        assertEq(announcer.getAnnouncementCount(), 2);
        assertEq(announcer.latestAnnouncementIndex(stealth1), 0);
        assertEq(announcer.latestAnnouncementIndex(stealth2), 1);
    }

    // ── Range Queries ──────────────────────────────────

    function test_getAnnouncements_range() public {
        // Publish 5 announcements
        for (uint256 i = 0; i < 5; i++) {
            address stealth = address(uint160(0x100 + i));
            announcer.publishAnnouncement(
                i + 1,
                27,
                stealth,
                bytes1(uint8(i)),
                ""
            );
        }

        // Get range [1, 3]
        StealthAddress.Announcement[] memory result = announcer
            .getAnnouncements(1, 3);
        assertEq(result.length, 3);
        assertEq(result[0].ephemeralPubKeyX, 2);
        assertEq(result[2].ephemeralPubKeyX, 4);
    }

    function test_getAnnouncements_beyondEnd() public {
        announcer.publishAnnouncement(
            0x01,
            27,
            makeAddr("s1"),
            bytes1(0x01),
            ""
        );
        announcer.publishAnnouncement(
            0x02,
            28,
            makeAddr("s2"),
            bytes1(0x02),
            ""
        );

        // Request more than available
        StealthAddress.Announcement[] memory result = announcer
            .getAnnouncements(0, 100);
        assertEq(result.length, 2);
    }

    function test_getAnnouncements_empty() public {
        StealthAddress.Announcement[] memory result = announcer
            .getAnnouncements(0, 10);
        assertEq(result.length, 0);
    }
}
