// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/PrivacyPool.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/interfaces/IProofVerifier.sol";

/// @notice Mock verifier that always returns true — for testing only.
contract MockVerifier is IProofVerifier {
    function verifyTransferProof(
        bytes calldata,
        bytes32,
        bytes32[2] calldata,
        bytes32[2] calldata,
        uint256,
        uint256
    ) external pure returns (bool) {
        return true;
    }

    function verifyWithdrawProof(
        bytes calldata,
        bytes32,
        bytes32[2] calldata,
        bytes32[2] calldata,
        address,
        uint256,
        uint256,
        uint256
    ) external pure returns (bool) {
        return true;
    }

    function verifyAggregatedProof(
        bytes calldata,
        bytes32[] calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function provingSystem() external pure returns (string memory) {
        return "mock";
    }
}

contract PrivacyPoolTest is Test {
    PrivacyPool public pool;
    EpochManager public epochManager;
    MockVerifier public verifier;

    address public deployer = address(1);
    address public alice = address(2);
    address public bob = address(3);

    uint256 constant DOMAIN_CHAIN_ID = 43113; // Fuji
    uint256 constant DOMAIN_APP_ID = 1;
    uint256 constant EPOCH_DURATION = 100; // blocks

    function setUp() public {
        vm.startPrank(deployer);

        verifier = new MockVerifier();
        epochManager = new EpochManager(EPOCH_DURATION, DOMAIN_CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(epochManager),
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID,
            deployer,
            address(0)
        );

        // Authorize the pool in the epoch manager
        epochManager.authorizePool(address(pool));

        vm.stopPrank();

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ── Deposit Tests ──────────────────────────────────

    function test_deposit() public {
        bytes32 commitment = keccak256("test commitment");

        vm.prank(alice);
        pool.deposit{value: 1 ether}(commitment);

        // Verify root changed
        bytes32 root = pool.getLatestRoot();
        assertTrue(root != bytes32(0), "Root should not be zero after deposit");
    }

    function test_deposit_emits_event() public {
        bytes32 commitment = keccak256("test commitment");

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit PrivacyPool.Deposit(commitment, 0, 1 ether);
        pool.deposit{value: 1 ether}(commitment);
    }

    function test_deposit_multiple() public {
        bytes32 c1 = keccak256("commitment 1");
        bytes32 c2 = keccak256("commitment 2");
        bytes32 c3 = keccak256("commitment 3");

        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(c1);
        pool.deposit{value: 2 ether}(c2);
        pool.deposit{value: 0.5 ether}(c3);
        vm.stopPrank();

        assertEq(pool.getNextLeafIndex(), 3, "Should have 3 leaves");
    }

    function test_deposit_zero_value_reverts() public {
        bytes32 commitment = keccak256("test");

        vm.prank(alice);
        vm.expectRevert();
        pool.deposit{value: 0}(commitment);
    }

    function test_deposit_duplicate_commitment_reverts() public {
        bytes32 commitment = keccak256("duplicate");

        vm.prank(alice);
        pool.deposit{value: 1 ether}(commitment);

        vm.prank(bob);
        vm.expectRevert();
        pool.deposit{value: 1 ether}(commitment);
    }

    // ── Root History Tests ─────────────────────────────

    function test_root_history() public {
        bytes32 c1 = keccak256("c1");
        bytes32 c2 = keccak256("c2");

        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(c1);
        bytes32 root1 = pool.getLatestRoot();

        pool.deposit{value: 1 ether}(c2);
        bytes32 root2 = pool.getLatestRoot();
        vm.stopPrank();

        assertTrue(root1 != root2, "Roots should differ");
        assertTrue(pool.isKnownRoot(root1), "Old root should still be known");
        assertTrue(pool.isKnownRoot(root2), "New root should be known");
    }

    function test_unknown_root() public {
        bytes32 fakeRoot = keccak256("fake root");
        assertFalse(pool.isKnownRoot(fakeRoot));
    }

    function test_zero_root_not_known() public {
        assertFalse(pool.isKnownRoot(bytes32(0)));
    }

    // ── Transfer Tests ─────────────────────────────────

    function test_transfer() public {
        // Deposit first
        bytes32 c1 = keccak256("input note 1");
        bytes32 c2 = keccak256("input note 2");

        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(c1);
        pool.deposit{value: 1 ether}(c2);
        vm.stopPrank();

        bytes32 root = pool.getLatestRoot();
        bytes32 nul1 = keccak256("nullifier 1");
        bytes32 nul2 = keccak256("nullifier 2");
        bytes32 out1 = keccak256("output 1");
        bytes32 out2 = keccak256("output 2");

        bytes memory proof = new bytes(512);

        vm.prank(alice);
        pool.transfer(proof, root, [nul1, nul2], [out1, out2]);

        // Nullifiers should be spent
        assertTrue(pool.isSpent(nul1));
        assertTrue(pool.isSpent(nul2));
    }

    function test_transfer_duplicate_nullifier_reverts() public {
        bytes32 c1 = keccak256("c1");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(c1);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul = keccak256("same nullifier");

        vm.prank(alice);
        vm.expectRevert();
        pool.transfer(
            new bytes(512),
            root,
            [nul, nul], // duplicate
            [keccak256("o1"), keccak256("o2")]
        );
    }

    function test_transfer_spent_nullifier_reverts() public {
        bytes32 c1 = keccak256("c1");
        bytes32 c2 = keccak256("c2");
        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(c1);
        pool.deposit{value: 1 ether}(c2);
        vm.stopPrank();

        bytes32 root = pool.getLatestRoot();
        bytes32 nul1 = keccak256("nul1");
        bytes32 nul2 = keccak256("nul2");

        // First transfer succeeds
        vm.prank(alice);
        pool.transfer(
            new bytes(512),
            root,
            [nul1, nul2],
            [keccak256("o1"), keccak256("o2")]
        );

        // Re-using nul1 should revert
        bytes32 root2 = pool.getLatestRoot();
        vm.prank(alice);
        vm.expectRevert();
        pool.transfer(
            new bytes(512),
            root2,
            [nul1, keccak256("nul3")],
            [keccak256("o3"), keccak256("o4")]
        );
    }

    // ── Withdraw Tests ─────────────────────────────────

    function test_withdraw() public {
        bytes32 c1 = keccak256("c1");
        vm.prank(alice);
        pool.deposit{value: 5 ether}(c1);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul1 = keccak256("wnul1");
        bytes32 nul2 = keccak256("wnul2");

        uint256 bobBalBefore = bob.balance;

        vm.prank(bob);
        pool.withdraw(
            new bytes(512),
            root,
            [nul1, nul2],
            [keccak256("wo1"), keccak256("wo2")],
            bob,
            3 ether
        );

        assertEq(
            bob.balance,
            bobBalBefore + 3 ether,
            "Bob should receive 3 ether"
        );
        assertTrue(pool.isSpent(nul1));
        assertTrue(pool.isSpent(nul2));
    }

    function test_withdraw_insufficient_balance_reverts() public {
        bytes32 c1 = keccak256("c1");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(c1);

        bytes32 root = pool.getLatestRoot();

        vm.prank(bob);
        vm.expectRevert();
        pool.withdraw(
            new bytes(512),
            root,
            [keccak256("n1"), keccak256("n2")],
            [keccak256("o1"), keccak256("o2")],
            bob,
            10 ether // more than deposited
        );
    }

    // ── Fuzz Tests ─────────────────────────────────────

    function testFuzz_deposit_various_amounts(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        bytes32 commitment = keccak256(abi.encodePacked("fuzz", amount));

        vm.deal(alice, amount);
        vm.prank(alice);
        pool.deposit{value: amount}(commitment);

        assertTrue(pool.getLatestRoot() != bytes32(0));
    }

    // ── Fixed Denomination Tests ───────────────────────

    function test_fixed_denomination_deposit() public {
        // Enable fixed denominations: 0.1, 1, 10 ETH
        uint256[] memory tiers = new uint256[](3);
        tiers[0] = 0.1 ether;
        tiers[1] = 1 ether;
        tiers[2] = 10 ether;

        vm.prank(deployer);
        pool.enableFixedDenominations(tiers);

        assertTrue(pool.fixedDenominationsEnabled());

        // Deposit at allowed tier works
        bytes32 commitment = keccak256("denom-1");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(commitment);
        assertTrue(pool.commitmentExists(commitment));
    }

    function test_fixed_denomination_rejects_invalid() public {
        uint256[] memory tiers = new uint256[](2);
        tiers[0] = 1 ether;
        tiers[1] = 10 ether;

        vm.prank(deployer);
        pool.enableFixedDenominations(tiers);

        // Non-tier amount should revert
        bytes32 commitment = keccak256("bad-denom");
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidDenomination.selector);
        pool.deposit{value: 0.5 ether}(commitment);
    }

    function test_fixed_denomination_commit_reveal() public {
        uint256[] memory tiers = new uint256[](1);
        tiers[0] = 1 ether;

        vm.prank(deployer);
        pool.enableFixedDenominations(tiers);

        // Commit at allowed tier
        bytes32 commitment = keccak256("cr-denom");
        bytes32 salt = keccak256("salt");
        bytes32 commitHash = keccak256(abi.encodePacked(commitment, salt));

        vm.prank(alice);
        pool.commitDeposit{value: 1 ether}(commitHash);

        // Non-tier commit should revert
        bytes32 commitHash2 = keccak256("bad-cr");
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidDenomination.selector);
        pool.commitDeposit{value: 0.5 ether}(commitHash2);
    }

    function test_disable_fixed_denominations() public {
        uint256[] memory tiers = new uint256[](1);
        tiers[0] = 1 ether;

        vm.prank(deployer);
        pool.enableFixedDenominations(tiers);
        assertTrue(pool.fixedDenominationsEnabled());

        vm.prank(deployer);
        pool.disableFixedDenominations();
        assertFalse(pool.fixedDenominationsEnabled());

        // Any amount should work again
        bytes32 commitment = keccak256("any-amount");
        vm.prank(alice);
        pool.deposit{value: 0.5 ether}(commitment);
        assertTrue(pool.commitmentExists(commitment));
    }

    function test_get_denomination_tiers() public {
        uint256[] memory tiers = new uint256[](3);
        tiers[0] = 0.1 ether;
        tiers[1] = 1 ether;
        tiers[2] = 10 ether;

        vm.prank(deployer);
        pool.enableFixedDenominations(tiers);

        uint256[] memory result = pool.getDenominationTiers();
        assertEq(result.length, 3);
        assertEq(result[0], 0.1 ether);
        assertEq(result[1], 1 ether);
        assertEq(result[2], 10 ether);
    }

    function test_only_governance_can_set_denominations() public {
        uint256[] memory tiers = new uint256[](1);
        tiers[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(PrivacyPool.Unauthorized.selector);
        pool.enableFixedDenominations(tiers);
    }
}
