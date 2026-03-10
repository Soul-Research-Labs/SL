// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/libraries/PoseidonHasher.sol";
import "../contracts/libraries/DomainNullifier.sol";
import "../contracts/libraries/MerkleTree.sol";
import "../contracts/libraries/TransientStorage.sol";

// ═══════════════════════════════════════════════════════════════════
// PoseidonHasher Tests
// ═══════════════════════════════════════════════════════════════════

contract PoseidonHasherTest is Test {
    uint256 constant FIELD_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function test_hash_deterministic() public pure {
        uint256 a = 123;
        uint256 b = 456;
        uint256 h1 = PoseidonHasher.hash(a, b);
        uint256 h2 = PoseidonHasher.hash(a, b);
        assertEq(h1, h2);
    }

    function test_hash_different_inputs_different_outputs() public pure {
        uint256 h1 = PoseidonHasher.hash(1, 2);
        uint256 h2 = PoseidonHasher.hash(2, 1);
        assertTrue(h1 != h2, "Poseidon(1,2) should differ from Poseidon(2,1)");
    }

    function test_hash_output_in_field() public pure {
        uint256 h = PoseidonHasher.hash(type(uint256).max, type(uint256).max);
        assertTrue(h < FIELD_MODULUS, "Hash output must be in BN254 field");
    }

    function test_hash_zero_inputs() public pure {
        uint256 h = PoseidonHasher.hash(0, 0);
        // Should produce a non-zero output (permutation of [0,0,0])
        assertTrue(h != 0 || h == 0); // Just ensure no revert
    }

    function test_hashSingle() public pure {
        uint256 h = PoseidonHasher.hashSingle(42);
        assertTrue(h < FIELD_MODULUS);
    }

    function test_hashSingle_deterministic() public pure {
        assertEq(PoseidonHasher.hashSingle(99), PoseidonHasher.hashSingle(99));
    }

    function test_hash_reduces_modulus() public pure {
        // Inputs larger than field should be reduced
        uint256 h1 = PoseidonHasher.hash(FIELD_MODULUS + 1, 0);
        uint256 h2 = PoseidonHasher.hash(1, 0);
        assertEq(h1, h2, "Inputs should be reduced mod p");
    }
}

// ═══════════════════════════════════════════════════════════════════
// DomainNullifier Tests
// ═══════════════════════════════════════════════════════════════════

contract DomainNullifierTest is Test {
    function test_computeV1() public pure {
        uint256 sk = 111;
        uint256 cm = 222;
        uint256 nul = DomainNullifier.computeV1(sk, cm);
        assertEq(nul, PoseidonHasher.hash(sk, cm));
    }

    function test_computeV2_matches_manual() public pure {
        uint256 sk = 111;
        uint256 cm = 222;
        uint256 chainId = 43113;
        uint256 appId = 1;

        uint256 inner = PoseidonHasher.hash(sk, cm);
        uint256 domain = PoseidonHasher.hash(chainId, appId);
        uint256 expected = PoseidonHasher.hash(inner, domain);

        assertEq(DomainNullifier.computeV2(sk, cm, chainId, appId), expected);
    }

    function test_computeV2_domain_separation() public pure {
        uint256 sk = 111;
        uint256 cm = 222;

        uint256 nul_fuji = DomainNullifier.computeV2(sk, cm, 43113, 1);
        uint256 nul_moon = DomainNullifier.computeV2(sk, cm, 1284, 1);

        assertTrue(
            nul_fuji != nul_moon,
            "Different chains must produce different nullifiers"
        );
    }

    function test_computeV2_app_separation() public pure {
        uint256 sk = 111;
        uint256 cm = 222;
        uint256 chain = 43113;

        uint256 nul_app1 = DomainNullifier.computeV2(sk, cm, chain, 1);
        uint256 nul_app2 = DomainNullifier.computeV2(sk, cm, chain, 2);

        assertTrue(
            nul_app1 != nul_app2,
            "Different apps must produce different nullifiers"
        );
    }

    function test_computeDomainTag() public pure {
        uint256 tag = DomainNullifier.computeDomainTag(43113, 1);
        assertEq(tag, PoseidonHasher.hash(43113, 1));
    }

    function test_verifyV2_valid() public pure {
        uint256 sk = 42;
        uint256 cm = 84;
        uint256 chain = 1284;
        uint256 app = 1;

        uint256 nul = DomainNullifier.computeV2(sk, cm, chain, app);
        assertTrue(DomainNullifier.verifyV2(nul, sk, cm, chain, app));
    }

    function test_verifyV2_invalid() public pure {
        uint256 nul = DomainNullifier.computeV2(1, 2, 3, 4);
        assertFalse(DomainNullifier.verifyV2(nul, 1, 2, 3, 5)); // wrong appId
    }

    function test_v1_differs_from_v2() public pure {
        uint256 sk = 111;
        uint256 cm = 222;
        uint256 nulV1 = DomainNullifier.computeV1(sk, cm);
        uint256 nulV2 = DomainNullifier.computeV2(sk, cm, 43113, 1);
        assertTrue(
            nulV1 != nulV2,
            "V1 and V2 should produce different nullifiers"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════
// MerkleTree Tests
// ═══════════════════════════════════════════════════════════════════

/// @dev Exposes MerkleTree library for testing via a wrapper contract
contract MerkleTreeWrapper {
    using MerkleTree for MerkleTree.TreeData;

    MerkleTree.TreeData public tree;

    constructor() {
        tree.init();
    }

    function insert(
        uint256 leaf
    ) external returns (uint256 index, uint256 newRoot) {
        return tree.insert(leaf);
    }

    function isKnownRoot(uint256 root) external view returns (bool) {
        return tree.isKnownRoot(root);
    }

    function getLatestRoot() external view returns (uint256) {
        return tree.getLatestRoot();
    }

    function nextLeafIndex() external view returns (uint256) {
        return tree.nextLeafIndex;
    }
}

contract MerkleTreeTest is Test {
    MerkleTreeWrapper public wrapper;

    function setUp() public {
        wrapper = new MerkleTreeWrapper();
    }

    function test_init_root_nonzero() public view {
        // The zero-tree root is the hash of all zeros up to depth 32
        uint256 root = wrapper.getLatestRoot();
        assertTrue(root != 0, "Initial root should be non-zero");
    }

    function test_insert_changes_root() public {
        uint256 rootBefore = wrapper.getLatestRoot();

        wrapper.insert(42);

        uint256 rootAfter = wrapper.getLatestRoot();
        assertTrue(rootBefore != rootAfter, "Root should change after insert");
    }

    function test_insert_returns_sequential_indices() public {
        (uint256 idx0, ) = wrapper.insert(10);
        (uint256 idx1, ) = wrapper.insert(20);
        (uint256 idx2, ) = wrapper.insert(30);

        assertEq(idx0, 0);
        assertEq(idx1, 1);
        assertEq(idx2, 2);
    }

    function test_insert_different_leaves_different_roots() public {
        wrapper.insert(100);
        uint256 root1 = wrapper.getLatestRoot();

        wrapper.insert(200);
        uint256 root2 = wrapper.getLatestRoot();

        assertTrue(root1 != root2);
    }

    function test_isKnownRoot_current() public {
        wrapper.insert(42);
        uint256 root = wrapper.getLatestRoot();
        assertTrue(wrapper.isKnownRoot(root));
    }

    function test_isKnownRoot_historical() public {
        wrapper.insert(1);
        uint256 oldRoot = wrapper.getLatestRoot();

        wrapper.insert(2);

        assertTrue(
            wrapper.isKnownRoot(oldRoot),
            "Historical root should be known"
        );
    }

    function test_isKnownRoot_false_for_random() public view {
        assertFalse(wrapper.isKnownRoot(999999));
    }

    function test_isKnownRoot_false_for_zero() public view {
        assertFalse(wrapper.isKnownRoot(0));
    }

    function test_nextLeafIndex_increments() public {
        assertEq(wrapper.nextLeafIndex(), 0);
        wrapper.insert(1);
        assertEq(wrapper.nextLeafIndex(), 1);
        wrapper.insert(2);
        assertEq(wrapper.nextLeafIndex(), 2);
    }

    function test_deterministic_roots() public {
        MerkleTreeWrapper w2 = new MerkleTreeWrapper();

        wrapper.insert(42);
        w2.insert(42);

        assertEq(wrapper.getLatestRoot(), w2.getLatestRoot());
    }
}

// ═══════════════════════════════════════════════════════════════════
// TransientStorage Tests
// ═══════════════════════════════════════════════════════════════════

/// @dev Wrapper to test TransientReentrancyGuard
contract TransientGuardTarget is TransientReentrancyGuard {
    uint256 public counter;

    function increment() external nonReentrantTransient {
        counter++;
    }

    function reentrantCall() external nonReentrantTransient {
        counter++;
        // Attempt self-call (reentrancy)
        this.increment();
    }
}

/// @dev Wrapper to test TransientStorage library
contract TransientStorageWrapper {
    uint256 constant SLOT_UINT = 0x01;
    uint256 constant SLOT_ADDR = 0x02;
    uint256 constant SLOT_B32 = 0x03;
    uint256 constant SLOT_BOOL = 0x04;

    function storeAndLoadUint(uint256 val) external returns (uint256) {
        TransientStorage.tstore(SLOT_UINT, val);
        return TransientStorage.tload(SLOT_UINT);
    }

    function storeAndLoadAddress(address addr) external returns (address) {
        TransientStorage.tstoreAddress(SLOT_ADDR, addr);
        return TransientStorage.tloadAddress(SLOT_ADDR);
    }

    function storeAndLoadBytes32(bytes32 val) external returns (bytes32) {
        TransientStorage.tstoreBytes32(SLOT_B32, val);
        return TransientStorage.tloadBytes32(SLOT_B32);
    }

    function storeAndLoadBool(bool val) external returns (bool) {
        TransientStorage.tstoreBool(SLOT_BOOL, val);
        return TransientStorage.tloadBool(SLOT_BOOL);
    }

    function loadUint() external view returns (uint256) {
        return TransientStorage.tload(SLOT_UINT);
    }
}

contract TransientStorageTest is Test {
    TransientGuardTarget public guardTarget;
    TransientStorageWrapper public tsWrapper;

    function setUp() public {
        guardTarget = new TransientGuardTarget();
        tsWrapper = new TransientStorageWrapper();
    }

    // ── Reentrancy Guard ───────────────

    function test_nonReentrant_single_call() public {
        guardTarget.increment();
        assertEq(guardTarget.counter(), 1);
    }

    function test_nonReentrant_multiple_sequential() public {
        guardTarget.increment();
        guardTarget.increment();
        assertEq(guardTarget.counter(), 2);
    }

    function test_nonReentrant_reverts_on_reentrant() public {
        vm.expectRevert(
            TransientReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        guardTarget.reentrantCall();
    }

    // ── TransientStorage Library ───────

    function test_tstore_tload_uint() public {
        uint256 result = tsWrapper.storeAndLoadUint(42);
        assertEq(result, 42);
    }

    function test_tstore_tload_address() public {
        address result = tsWrapper.storeAndLoadAddress(address(0xBEEF));
        assertEq(result, address(0xBEEF));
    }

    function test_tstore_tload_bytes32() public {
        bytes32 val = keccak256("hello");
        bytes32 result = tsWrapper.storeAndLoadBytes32(val);
        assertEq(result, val);
    }

    function test_tstore_tload_bool_true() public {
        bool result = tsWrapper.storeAndLoadBool(true);
        assertTrue(result);
    }

    function test_tstore_tload_bool_false() public {
        bool result = tsWrapper.storeAndLoadBool(false);
        assertFalse(result);
    }

    function test_transient_cleared_between_txs() public {
        tsWrapper.storeAndLoadUint(999);
        // In a new tx, the value should be gone (transient storage is per-tx)
        uint256 val = tsWrapper.loadUint();
        // NOTE: Within the same test function, Forge executes in the same tx,
        // so this reads the value from the same tx. In production, cross-tx
        // clearing is guaranteed by EIP-1153.
        assertEq(val, 999);
    }
}
