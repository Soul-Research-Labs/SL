// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/libraries/TransientStorage.sol";

// ═══════════════════════════════════════════════════════════════════
// TransientStorage Library Tests
// ═══════════════════════════════════════════════════════════════════

contract TransientStorageTest is Test {
    uint256 constant SLOT_A = 0x01;
    uint256 constant SLOT_B = 0x02;
    uint256 constant SLOT_C = 0x03;
    uint256 constant SLOT_D = 0x04;
    uint256 constant SLOT_E = 0x05;

    // ── uint256 ────────────────────────────────────────────────────

    function test_tstore_tload_uint256() public {
        TransientStorage.tstore(SLOT_A, 42);
        assertEq(TransientStorage.tload(SLOT_A), 42);
    }

    function test_tload_default_zero() public view {
        // Unwritten slot should return zero
        assertEq(TransientStorage.tload(0xDEAD), 0);
    }

    function test_tstore_overwrite() public {
        TransientStorage.tstore(SLOT_A, 100);
        TransientStorage.tstore(SLOT_A, 200);
        assertEq(TransientStorage.tload(SLOT_A), 200);
    }

    function test_tstore_max_uint256() public {
        TransientStorage.tstore(SLOT_A, type(uint256).max);
        assertEq(TransientStorage.tload(SLOT_A), type(uint256).max);
    }

    // ── address ────────────────────────────────────────────────────

    function test_tstore_tload_address() public {
        address expected = address(0xBEEF);
        TransientStorage.tstoreAddress(SLOT_B, expected);
        assertEq(TransientStorage.tloadAddress(SLOT_B), expected);
    }

    function test_tload_address_default_zero() public view {
        assertEq(TransientStorage.tloadAddress(0xBEEF), address(0));
    }

    // ── bytes32 ────────────────────────────────────────────────────

    function test_tstore_tload_bytes32() public {
        bytes32 val = keccak256("hello");
        TransientStorage.tstoreBytes32(SLOT_C, val);
        assertEq(TransientStorage.tloadBytes32(SLOT_C), val);
    }

    function test_tload_bytes32_default_zero() public view {
        assertEq(TransientStorage.tloadBytes32(0xCAFE), bytes32(0));
    }

    // ── bool ───────────────────────────────────────────────────────

    function test_tstore_tload_bool_true() public {
        TransientStorage.tstoreBool(SLOT_D, true);
        assertTrue(TransientStorage.tloadBool(SLOT_D));
    }

    function test_tstore_tload_bool_false() public {
        TransientStorage.tstoreBool(SLOT_D, true);
        TransientStorage.tstoreBool(SLOT_D, false);
        assertFalse(TransientStorage.tloadBool(SLOT_D));
    }

    function test_tload_bool_default_false() public view {
        assertFalse(TransientStorage.tloadBool(0xF00D));
    }

    // ── deriveSlot (uint256 key) ───────────────────────────────────

    function test_deriveSlot_uint256_deterministic() public pure {
        uint256 s1 = TransientStorage.deriveSlot(SLOT_E, uint256(1));
        uint256 s2 = TransientStorage.deriveSlot(SLOT_E, uint256(1));
        assertEq(s1, s2);
    }

    function test_deriveSlot_uint256_different_keys() public pure {
        uint256 s1 = TransientStorage.deriveSlot(SLOT_E, uint256(1));
        uint256 s2 = TransientStorage.deriveSlot(SLOT_E, uint256(2));
        assertTrue(s1 != s2, "Different keys must derive different slots");
    }

    function test_deriveSlot_uint256_different_bases() public pure {
        uint256 s1 = TransientStorage.deriveSlot(0x10, uint256(1));
        uint256 s2 = TransientStorage.deriveSlot(0x20, uint256(1));
        assertTrue(s1 != s2, "Different bases must derive different slots");
    }

    function test_deriveSlot_matches_keccak() public pure {
        uint256 base = 0x42;
        uint256 key = 99;
        uint256 derived = TransientStorage.deriveSlot(base, key);
        uint256 expected = uint256(keccak256(abi.encode(key, base)));
        assertEq(derived, expected);
    }

    // ── deriveSlot (bytes32 key) ───────────────────────────────────

    function test_deriveSlot_bytes32_deterministic() public pure {
        bytes32 key = bytes32(uint256(1));
        uint256 s1 = TransientStorage.deriveSlot(SLOT_E, key);
        uint256 s2 = TransientStorage.deriveSlot(SLOT_E, key);
        assertEq(s1, s2);
    }

    function test_deriveSlot_bytes32_different_keys() public pure {
        uint256 s1 = TransientStorage.deriveSlot(
            SLOT_E,
            bytes32(uint256(1))
        );
        uint256 s2 = TransientStorage.deriveSlot(
            SLOT_E,
            bytes32(uint256(2))
        );
        assertTrue(s1 != s2);
    }

    // ── Slot isolation ─────────────────────────────────────────────

    function test_different_slots_independent() public {
        TransientStorage.tstore(SLOT_A, 111);
        TransientStorage.tstore(SLOT_B, 222);
        assertEq(TransientStorage.tload(SLOT_A), 111);
        assertEq(TransientStorage.tload(SLOT_B), 222);
    }

    function test_derived_slot_usable_for_storage() public {
        uint256 slot = TransientStorage.deriveSlot(0x100, uint256(5));
        TransientStorage.tstore(slot, 999);
        assertEq(TransientStorage.tload(slot), 999);
    }
}

// ═══════════════════════════════════════════════════════════════════
// TransientReentrancyGuard Tests
// ═══════════════════════════════════════════════════════════════════

/// @dev Wrapper contract that exposes the guard for testing.
contract GuardedContract is TransientReentrancyGuard {
    uint256 public counter;

    function guarded() external nonReentrantTransient {
        counter += 1;
    }

    function guardedReenter(
        address target
    ) external nonReentrantTransient {
        counter += 1;
        // Attempt reentrant call
        (bool success, ) = target.call(
            abi.encodeWithSignature("guarded()")
        );
        // The inner call should revert, but we swallow it to test
        require(!success, "Reentrant call should have failed");
    }

    function guardedTwoCalls() external {
        // Two sequential guarded calls in the same tx should both succeed
        this.guarded();
        this.guarded();
    }
}

contract ReentrancyGuardTest is Test {
    GuardedContract public guarded;

    function setUp() public {
        guarded = new GuardedContract();
    }

    function test_single_call_succeeds() public {
        guarded.guarded();
        assertEq(guarded.counter(), 1);
    }

    function test_sequential_calls_succeed() public {
        guarded.guarded();
        guarded.guarded();
        assertEq(guarded.counter(), 2);
    }

    function test_reentrant_call_reverts() public {
        // guardedReenter attempts reentry — inner call reverts
        guarded.guardedReenter(address(guarded));
        // Only the outer call incremented counter
        assertEq(guarded.counter(), 1);
    }

    function test_sequential_guarded_in_same_tx() public {
        guarded.guardedTwoCalls();
        assertEq(guarded.counter(), 2);
    }
}
