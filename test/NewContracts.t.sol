// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/StealthAnnouncer.sol";
import "../contracts/core/ComplianceOracle.sol";
import "../contracts/core/RelayerFeeVault.sol";

// ═══════════════════════════════════════════════════════
//  StealthAnnouncer Tests
// ═══════════════════════════════════════════════════════

contract StealthAnnouncerTest is Test {
    StealthAnnouncer public announcer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        announcer = new StealthAnnouncer();
    }

    function test_registerMetaAddress() public {
        vm.prank(alice);
        announcer.registerMetaAddress(123, 27, 456, 28);

        assertTrue(announcer.hasMetaAddress(alice));
        StealthAddress.MetaAddress memory meta = announcer.getMetaAddress(
            alice
        );
        assertEq(meta.spendPubKeyX, 123);
        assertEq(meta.spendPubKeyParity, 27);
        assertEq(meta.viewPubKeyX, 456);
        assertEq(meta.viewPubKeyParity, 28);
    }

    function test_registerMetaAddress_invalidParity() public {
        vm.prank(alice);
        vm.expectRevert("Invalid spend parity");
        announcer.registerMetaAddress(123, 26, 456, 28);
    }

    function test_registerMetaAddress_update() public {
        vm.startPrank(alice);
        announcer.registerMetaAddress(100, 27, 200, 27);
        announcer.registerMetaAddress(300, 28, 400, 28);
        vm.stopPrank();

        StealthAddress.MetaAddress memory meta = announcer.getMetaAddress(
            alice
        );
        assertEq(meta.spendPubKeyX, 300);
    }

    function test_publishAnnouncement() public {
        address stealth = makeAddr("stealth");

        announcer.publishAnnouncement(
            999, // ephemeralPubKeyX
            27, // ephemeralPubKeyParity
            stealth,
            bytes1(0xAB), // viewTag
            "" // metadata
        );

        assertEq(announcer.getAnnouncementCount(), 1);
        assertEq(announcer.latestAnnouncementIndex(stealth), 0);
    }

    function test_publishMultipleAnnouncements() public {
        for (uint256 i = 0; i < 5; i++) {
            address stealth = address(uint160(i + 1));
            announcer.publishAnnouncement(i, 27, stealth, bytes1(uint8(i)), "");
        }
        assertEq(announcer.getAnnouncementCount(), 5);
    }

    function test_getAnnouncements_range() public {
        for (uint256 i = 0; i < 10; i++) {
            announcer.publishAnnouncement(
                i,
                27,
                address(uint160(i + 1)),
                bytes1(uint8(i)),
                ""
            );
        }

        StealthAddress.Announcement[] memory results = announcer
            .getAnnouncements(3, 4);
        assertEq(results.length, 4);
        assertEq(results[0].ephemeralPubKeyX, 3);
        assertEq(results[3].ephemeralPubKeyX, 6);
    }

    function test_getAnnouncements_clampedToLength() public {
        announcer.publishAnnouncement(1, 27, makeAddr("s1"), bytes1(0x01), "");

        StealthAddress.Announcement[] memory results = announcer
            .getAnnouncements(0, 100);
        assertEq(results.length, 1);
    }

    function test_getMetaAddress_unregistered_reverts() public {
        vm.expectRevert("No meta-address registered");
        announcer.getMetaAddress(bob);
    }
}

// ═══════════════════════════════════════════════════════
//  ComplianceOracle Tests
// ═══════════════════════════════════════════════════════

contract ComplianceOracleTest is Test {
    ComplianceOracle public oracle;
    address gov;
    address auditor = makeAddr("auditor");
    address user = makeAddr("user");

    function setUp() public {
        oracle = new ComplianceOracle();
        gov = address(this);
    }

    function test_initialState() public view {
        assertTrue(oracle.complianceEnabled());
        assertEq(oracle.policyVersion(), 1);
        assertEq(oracle.governance(), gov);
    }

    function test_checkCompliance_default_passes() public view {
        bytes32[2] memory nullifiers = [
            bytes32(uint256(1)),
            bytes32(uint256(2))
        ];
        bytes32[2] memory outputs = [bytes32(uint256(3)), bytes32(uint256(4))];
        assertTrue(oracle.checkCompliance(nullifiers, outputs, ""));
    }

    function test_blockAddress() public {
        oracle.blockAddress(user, "sanctioned");
        assertTrue(oracle.isBlocked(user));
    }

    function test_unblockAddress() public {
        oracle.blockAddress(user, "sanctioned");
        oracle.unblockAddress(user);
        assertFalse(oracle.isBlocked(user));
    }

    function test_blockCommitment_fails_compliance() public {
        bytes32 tainted = bytes32(uint256(42));
        oracle.blockCommitment(tainted, "tainted note");

        bytes32[2] memory nullifiers = [tainted, bytes32(uint256(2))];
        bytes32[2] memory outputs = [bytes32(uint256(3)), bytes32(uint256(4))];
        assertFalse(oracle.checkCompliance(nullifiers, outputs, ""));
    }

    function test_blockOutputCommitment_fails_compliance() public {
        bytes32 tainted = bytes32(uint256(99));
        oracle.blockCommitment(tainted, "bad output");

        bytes32[2] memory nullifiers = [
            bytes32(uint256(1)),
            bytes32(uint256(2))
        ];
        bytes32[2] memory outputs = [tainted, bytes32(uint256(4))];
        assertFalse(oracle.checkCompliance(nullifiers, outputs, ""));
    }

    function test_disableCompliance_everything_passes() public {
        bytes32 tainted = bytes32(uint256(42));
        oracle.blockCommitment(tainted, "tainted");
        oracle.setComplianceEnabled(false);

        bytes32[2] memory nullifiers = [tainted, bytes32(uint256(2))];
        bytes32[2] memory outputs = [bytes32(uint256(3)), bytes32(uint256(4))];
        assertTrue(oracle.checkCompliance(nullifiers, outputs, ""));
    }

    function test_addAuditor() public {
        oracle.addAuditor(auditor);
        assertTrue(oracle.authorizedAuditors(auditor));
    }

    function test_removeAuditor() public {
        oracle.addAuditor(auditor);
        oracle.removeAuditor(auditor);
        assertFalse(oracle.authorizedAuditors(auditor));
    }

    function test_updatePolicy() public {
        oracle.updatePolicy();
        assertEq(oracle.policyVersion(), 2);
        oracle.updatePolicy();
        assertEq(oracle.policyVersion(), 3);
    }

    function test_transferGovernance() public {
        address newGov = makeAddr("newGov");
        oracle.transferGovernance(newGov);
        assertEq(oracle.governance(), newGov);
    }

    function test_nonGovernance_reverts() public {
        vm.prank(user);
        vm.expectRevert("ComplianceOracle: not governance");
        oracle.blockAddress(user, "should fail");
    }

    function test_viewingKeyProof_passes() public view {
        bytes32[2] memory nullifiers = [
            bytes32(uint256(1)),
            bytes32(uint256(2))
        ];
        bytes32[2] memory outputs = [bytes32(uint256(3)), bytes32(uint256(4))];
        assertTrue(oracle.checkCompliance(nullifiers, outputs, hex"aabbcc"));
    }
}

// ═══════════════════════════════════════════════════════
//  RelayerFeeVault Tests
// ═══════════════════════════════════════════════════════

contract RelayerFeeVaultTest is Test {
    RelayerFeeVault public vault;
    address gov;
    address relayer1 = makeAddr("relayer1");
    address relayer2 = makeAddr("relayer2");

    uint256 constant FEE = 0.001 ether;
    uint256 constant MAX_FEE = 0.01 ether;
    uint256 constant MIN_STAKE = 1 ether;

    function setUp() public {
        vault = new RelayerFeeVault(FEE, MAX_FEE, MIN_STAKE);
        gov = address(this);
        deal(relayer1, 10 ether);
        deal(relayer2, 10 ether);
    }

    function test_registerRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        assertTrue(vault.registeredRelayers(relayer1));
        assertEq(vault.stakedAmount(relayer1), MIN_STAKE);
    }

    function test_registerRelayer_insufficientStake() public {
        vm.prank(relayer1);
        vm.expectRevert("FeeVault: insufficient stake");
        vault.registerRelayer{value: 0.5 ether}();
    }

    function test_registerRelayer_alreadyRegistered() public {
        vm.startPrank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vm.expectRevert("FeeVault: already registered");
        vault.registerRelayer{value: MIN_STAKE}();
        vm.stopPrank();
    }

    function test_depositFees() public {
        vault.depositFees{value: 1 ether}();
        assertEq(vault.vaultBalance(), 1 ether);
    }

    function test_depositFees_receive() public {
        (bool sent, ) = address(vault).call{value: 0.5 ether}("");
        assertTrue(sent);
        assertEq(vault.vaultBalance(), 0.5 ether);
    }

    function test_creditRelay() public {
        // Register relayer and fund vault
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        bytes32 relayHash = keccak256("relay1");
        vault.creditRelay(relayer1, relayHash, 43113, 1287, 0);

        assertEq(vault.claimableBalance(relayer1), FEE);
        assertEq(vault.relayCount(relayer1), 1);
        assertTrue(vault.relayProcessed(relayHash));
    }

    function test_creditRelay_duplicateReverts() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        bytes32 relayHash = keccak256("relay1");
        vault.creditRelay(relayer1, relayHash, 43113, 1287, 0);

        vm.expectRevert("FeeVault: relay already processed");
        vault.creditRelay(relayer1, relayHash, 43113, 1287, 0);
    }

    function test_claimFees() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();

        // Credit 3 relays
        for (uint256 i = 0; i < 3; i++) {
            vault.creditRelay(
                relayer1,
                keccak256(abi.encodePacked(i)),
                43113,
                1287,
                uint64(i)
            );
        }

        uint256 expected = FEE * 3;
        uint256 balBefore = relayer1.balance;

        vm.prank(relayer1);
        vault.claimFees();

        assertEq(relayer1.balance - balBefore, expected);
        assertEq(vault.claimableBalance(relayer1), 0);
    }

    function test_claimFees_nothingToClaim() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: nothing to claim");
        vault.claimFees();
    }

    function test_deregisterRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        uint256 balBefore = relayer1.balance;
        vm.prank(relayer1);
        vault.deregisterRelayer();

        assertFalse(vault.registeredRelayers(relayer1));
        assertEq(relayer1.balance - balBefore, MIN_STAKE);
    }

    function test_deregisterRelayer_pendingClaims() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();
        vault.creditRelay(relayer1, keccak256("r1"), 1, 2, 0);

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: claim fees first");
        vault.deregisterRelayer();
    }

    function test_slashRelayer() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        uint256 slashAmount = 0.5 ether;
        vault.slashRelayer(relayer1, slashAmount, "incorrect root");

        assertEq(vault.stakedAmount(relayer1), MIN_STAKE - slashAmount);
        assertEq(vault.vaultBalance(), slashAmount); // slashed funds go to vault
    }

    function test_slashRelayer_belowMinimum_deregisters() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vault.slashRelayer(relayer1, MIN_STAKE, "critical misbehavior");

        assertFalse(vault.registeredRelayers(relayer1));
        assertEq(vault.stakedAmount(relayer1), 0);
    }

    function test_setFeePerRelay() public {
        vault.setFeePerRelay(0.005 ether);
        assertEq(vault.feePerRelay(), 0.005 ether);
    }

    function test_setFeePerRelay_exceedsMax() public {
        vm.expectRevert("FeeVault: exceeds max");
        vault.setFeePerRelay(0.02 ether);
    }

    function test_getRelayerStats() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();
        vault.depositFees{value: 1 ether}();
        vault.creditRelay(relayer1, keccak256("r1"), 1, 2, 0);

        (
            bool registered,
            uint256 stake,
            uint256 pending,
            uint256 totalRelays
        ) = vault.getRelayerStats(relayer1);

        assertTrue(registered);
        assertEq(stake, MIN_STAKE);
        assertEq(pending, FEE);
        assertEq(totalRelays, 1);
    }

    function test_nonGovernance_creditReverts() public {
        vm.prank(relayer1);
        vault.registerRelayer{value: MIN_STAKE}();

        vm.prank(relayer1);
        vm.expectRevert("FeeVault: not governance");
        vault.creditRelay(relayer1, keccak256("r1"), 1, 2, 0);
    }

    receive() external payable {}
}
