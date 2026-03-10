// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/GovernanceTimelock.sol";
import "../contracts/core/EmergencyPause.sol";
import "../contracts/core/StealthAnnouncer.sol";
import "../contracts/libraries/StealthAddress.sol";

// ═══════════════════════════════════════════════════════
//  Governance Timelock Tests
// ═══════════════════════════════════════════════════════

/// @dev Dummy target for timelock test calls.
contract Counter {
    uint256 public value;

    function increment() external {
        value += 1;
    }

    function setValue(uint256 _v) external {
        value = _v;
    }
}

contract GovernanceTimelockTest is Test {
    GovernanceTimelock public timelock;
    Counter public counter;
    address admin = makeAddr("admin");

    uint256 constant DELAY = 2 days;

    function setUp() public {
        timelock = new GovernanceTimelock(admin, DELAY);
        counter = new Counter();
    }

    function test_constructor() public view {
        assertEq(timelock.admin(), admin);
        assertEq(timelock.delay(), DELAY);
    }

    function test_constructor_delayTooShort() public {
        vm.expectRevert(GovernanceTimelock.InvalidDelay.selector);
        new GovernanceTimelock(admin, 30 minutes);
    }

    function test_constructor_delayTooLong() public {
        vm.expectRevert(GovernanceTimelock.InvalidDelay.selector);
        new GovernanceTimelock(admin, 60 days);
    }

    function test_queueAndExecute() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        bytes32 txHash = timelock.queueTransaction(
            address(counter),
            0,
            data,
            eta
        );

        assertTrue(timelock.isQueued(txHash));

        // Warp past delay
        vm.warp(eta);
        vm.prank(admin);
        timelock.executeTransaction(address(counter), 0, data, eta);

        assertEq(counter.value(), 1);
        assertFalse(timelock.isQueued(txHash));
    }

    function test_executeBeforeEta_reverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        timelock.queueTransaction(address(counter), 0, data, eta);

        vm.prank(admin);
        vm.expectRevert(GovernanceTimelock.TransactionNotReady.selector);
        timelock.executeTransaction(address(counter), 0, data, eta);
    }

    function test_executeStaleTx_reverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        timelock.queueTransaction(address(counter), 0, data, eta);

        // Warp past grace period
        vm.warp(eta + 14 days + 1);
        vm.prank(admin);
        vm.expectRevert(GovernanceTimelock.TransactionStale.selector);
        timelock.executeTransaction(address(counter), 0, data, eta);
    }

    function test_cancelTransaction() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        bytes32 txHash = timelock.queueTransaction(
            address(counter),
            0,
            data,
            eta
        );

        vm.prank(admin);
        timelock.cancelTransaction(address(counter), 0, data, eta);

        assertFalse(timelock.isQueued(txHash));
    }

    function test_executeCancelledTx_reverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        timelock.queueTransaction(address(counter), 0, data, eta);

        vm.prank(admin);
        timelock.cancelTransaction(address(counter), 0, data, eta);

        vm.warp(eta);
        vm.prank(admin);
        vm.expectRevert(GovernanceTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(address(counter), 0, data, eta);
    }

    function test_doubleQueue_reverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.startPrank(admin);
        timelock.queueTransaction(address(counter), 0, data, eta);
        vm.expectRevert(GovernanceTimelock.TransactionAlreadyQueued.selector);
        timelock.queueTransaction(address(counter), 0, data, eta);
        vm.stopPrank();
    }

    function test_nonAdmin_reverts() public {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        uint256 eta = block.timestamp + DELAY;

        vm.expectRevert(GovernanceTimelock.Unauthorized.selector);
        timelock.queueTransaction(address(counter), 0, data, eta);
    }

    function test_adminTransfer_twoStep() public {
        address newAdmin = makeAddr("newAdmin");

        // setPendingAdmin must go through the timelock itself
        bytes memory setData = abi.encodeCall(
            GovernanceTimelock.setPendingAdmin,
            (newAdmin)
        );
        uint256 eta = block.timestamp + DELAY;

        vm.prank(admin);
        timelock.queueTransaction(address(timelock), 0, setData, eta);

        vm.warp(eta);
        vm.prank(admin);
        timelock.executeTransaction(address(timelock), 0, setData, eta);

        assertEq(timelock.pendingAdmin(), newAdmin);

        vm.prank(newAdmin);
        timelock.acceptAdmin();

        assertEq(timelock.admin(), newAdmin);
        assertEq(timelock.pendingAdmin(), address(0));
    }

    function test_executeWithValue() public {
        // Fund the timelock
        vm.deal(address(timelock), 1 ether);

        bytes memory data = "";
        uint256 eta = block.timestamp + DELAY;

        address receiver = makeAddr("receiver");

        vm.prank(admin);
        timelock.queueTransaction(receiver, 0.5 ether, data, eta);

        vm.warp(eta);
        vm.prank(admin);
        timelock.executeTransaction(receiver, 0.5 ether, data, eta);

        assertEq(receiver.balance, 0.5 ether);
    }

    function test_computeTxHash() public view {
        bytes memory data = abi.encodeCall(Counter.increment, ());
        bytes32 expected = keccak256(
            abi.encode(address(counter), 0, data, 1000)
        );
        assertEq(
            timelock.computeTxHash(address(counter), 0, data, 1000),
            expected
        );
    }
}

// ═══════════════════════════════════════════════════════
//  Emergency Pause Tests
// ═══════════════════════════════════════════════════════

/// @dev Concrete implementation of EmergencyPause for testing.
contract PausablePool is EmergencyPause {
    address public governance;
    uint256 public deposits;

    constructor(address _governance, address _guardian) {
        governance = _governance;
        _initPause(_guardian);
    }

    function _pauseGovernance() internal view override returns (address) {
        return governance;
    }

    function deposit() external whenNotPaused {
        deposits += 1;
    }
}

contract EmergencyPauseTest is Test {
    PausablePool public pool;
    address gov = makeAddr("gov");
    address guard = makeAddr("guardian");
    address user = makeAddr("user");

    function setUp() public {
        pool = new PausablePool(gov, guard);
    }

    function test_initiallyNotPaused() public view {
        assertFalse(pool.paused());
        assertEq(pool.guardian(), guard);
    }

    function test_guardianCanPause() public {
        vm.prank(guard);
        pool.pause("suspicious activity");

        assertTrue(pool.paused());
        assertEq(pool.pauseCount(), 1);
    }

    function test_governanceCanPause() public {
        vm.prank(gov);
        pool.pause("maintenance");

        assertTrue(pool.paused());
    }

    function test_randomUserCannotPause() public {
        vm.prank(user);
        vm.expectRevert(EmergencyPause.NotGuardianOrGovernance.selector);
        pool.pause("hax0r");
    }

    function test_depositRevertsWhenPaused() public {
        vm.prank(guard);
        pool.pause("reason");

        vm.expectRevert(EmergencyPause.ContractPaused.selector);
        pool.deposit();
    }

    function test_governanceCanUnpause() public {
        vm.prank(guard);
        pool.pause("reason");

        vm.prank(gov);
        pool.unpause();

        assertFalse(pool.paused());
    }

    function test_guardianCannotUnpause() public {
        vm.prank(guard);
        pool.pause("reason");

        vm.prank(guard);
        vm.expectRevert(EmergencyPause.NotGovernance.selector);
        pool.unpause();
    }

    function test_anyoneCanUnpauseAfterMaxDuration() public {
        vm.prank(guard);
        pool.pause("reason");

        // Warp past MAX_PAUSE_DURATION (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(user);
        pool.unpause();

        assertFalse(pool.paused());
    }

    function test_setGuardian() public {
        address newGuard = makeAddr("newGuardian");

        vm.prank(gov);
        pool.setGuardian(newGuard);

        assertEq(pool.guardian(), newGuard);
    }

    function test_setGuardian_nonGov_reverts() public {
        vm.prank(user);
        vm.expectRevert(EmergencyPause.NotGovernance.selector);
        pool.setGuardian(user);
    }

    function test_pauseCount_increments() public {
        vm.startPrank(guard);
        pool.pause("first");
        vm.stopPrank();

        vm.prank(gov);
        pool.unpause();

        vm.prank(guard);
        pool.pause("second");

        assertEq(pool.pauseCount(), 2);
    }

    function test_doublePause_reverts() public {
        vm.startPrank(guard);
        pool.pause("first");
        vm.expectRevert(EmergencyPause.ContractPaused.selector);
        pool.pause("second");
        vm.stopPrank();
    }

    function test_unpauseWhenNotPaused_reverts() public {
        vm.prank(gov);
        vm.expectRevert(EmergencyPause.ContractNotPaused.selector);
        pool.unpause();
    }
}

// ═══════════════════════════════════════════════════════
//  Stealth Full-Flow Integration Test
// ═══════════════════════════════════════════════════════

contract StealthFlowTest is Test {
    StealthAnnouncer public announcer;

    function setUp() public {
        announcer = new StealthAnnouncer();
    }

    /// @notice Full stealth flow: register → announce → scan → verify
    function test_fullStealthFlow() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        // Step 1: Bob registers a stealth meta-address
        vm.prank(bob);
        announcer.registerMetaAddress(
            uint256(keccak256("bob-spend-key")),
            27,
            uint256(keccak256("bob-view-key")),
            28
        );

        assertTrue(announcer.hasMetaAddress(bob));

        // Step 2: Alice retrieves Bob's meta-address
        StealthAddress.MetaAddress memory meta = announcer.getMetaAddress(bob);
        assertEq(meta.spendPubKeyX, uint256(keccak256("bob-spend-key")));
        assertEq(meta.viewPubKeyX, uint256(keccak256("bob-view-key")));

        // Step 3: Alice generates an ephemeral key and computes stealth address
        //         (Simulated on-chain — in production this is off-chain)
        uint256 ephemeralPrivKey = uint256(keccak256("alice-ephemeral"));
        uint256 ephemeralPubKeyX = uint256(
            keccak256(abi.encodePacked(ephemeralPrivKey, "pub"))
        );

        // Compute view tag (first byte of shared secret hash)
        bytes32 sharedSecret = keccak256(
            abi.encodePacked(ephemeralPrivKey, meta.viewPubKeyX)
        );
        bytes1 viewTag = sharedSecret[0];

        // Derive stealth address (simplified)
        address stealthAddr = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            meta.spendPubKeyX,
                            meta.spendPubKeyParity,
                            uint256(sharedSecret) % StealthAddress.SECP256K1_N
                        )
                    )
                )
            )
        );

        // Step 4: Alice publishes the announcement
        vm.prank(alice);
        announcer.publishAnnouncement(
            ephemeralPubKeyX,
            27,
            stealthAddr,
            viewTag,
            ""
        );

        assertEq(announcer.getAnnouncementCount(), 1);

        // Step 5: Bob scans announcements and finds the one addressed to him
        StealthAddress.Announcement[] memory anns = announcer.getAnnouncements(
            0,
            10
        );
        assertEq(anns.length, 1);
        assertEq(anns[0].stealthAddress, stealthAddr);
        assertEq(anns[0].viewTag, viewTag);

        // Step 6: Verify stealth address is unique per announcement
        uint256 ephemeralPrivKey2 = uint256(keccak256("alice-ephemeral-2"));
        bytes32 sharedSecret2 = keccak256(
            abi.encodePacked(ephemeralPrivKey2, meta.viewPubKeyX)
        );
        address stealthAddr2 = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            meta.spendPubKeyX,
                            meta.spendPubKeyParity,
                            uint256(sharedSecret2) % StealthAddress.SECP256K1_N
                        )
                    )
                )
            )
        );
        assertTrue(
            stealthAddr != stealthAddr2,
            "Each ephemeral key should yield a unique stealth address"
        );
    }

    function test_multipleAnnouncementsScanning() public {
        address bob = makeAddr("bob");

        // Bob registers
        vm.prank(bob);
        announcer.registerMetaAddress(100, 27, 200, 28);

        // Publish 5 announcements from different senders
        for (uint256 i = 0; i < 5; i++) {
            address sender = address(uint160(i + 10));
            vm.prank(sender);
            announcer.publishAnnouncement(
                i * 1000,
                27,
                address(uint160(i + 100)),
                bytes1(uint8(i)),
                abi.encodePacked("metadata-", i)
            );
        }

        assertEq(announcer.getAnnouncementCount(), 5);

        // Bob can scan paginated results
        StealthAddress.Announcement[] memory page1 = announcer.getAnnouncements(
            0,
            3
        );
        assertEq(page1.length, 3);

        StealthAddress.Announcement[] memory page2 = announcer.getAnnouncements(
            3,
            3
        );
        assertEq(page2.length, 2);
    }
}
