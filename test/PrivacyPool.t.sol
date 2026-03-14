// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/PrivacyPool.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/interfaces/IProofVerifier.sol";

contract MockVerifier is IProofVerifier {
    function verifyTransferProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function verifyWithdrawProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function verifyAggregatedProof(
        bytes calldata,
        uint256[] calldata
    ) external pure returns (bool) {
        return true;
    }

    function provingSystem() external pure returns (string memory) {
        return "mock";
    }
}

contract ReentrancyAttacker {
    PrivacyPool public target;
    bool public attacked;

    constructor(address _pool) {
        target = PrivacyPool(payable(_pool));
    }

    function attack(
        bytes calldata proof,
        bytes32 root,
        bytes32[2] calldata nullifiers,
        bytes32[2] calldata outputs,
        uint256 exitValue
    ) external {
        target.withdraw(
            proof,
            root,
            nullifiers,
            outputs,
            payable(address(this)),
            exitValue
        );
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            try
                target.withdraw(
                    new bytes(512),
                    target.getLatestRoot(),
                    [keccak256("re-nul1"), keccak256("re-nul2")],
                    [keccak256("re-out1"), keccak256("re-out2")],
                    payable(address(this)),
                    1 ether
                )
            {} catch {}
        }
    }
}

contract PrivacyPoolTest is Test {
    PrivacyPool public pool;
    EpochManager public epochManager;
    MockVerifier public verifier;

    address public deployer = address(1);
    address public alice = address(2);
    address public bob = address(3);

    uint256 constant DOMAIN_CHAIN_ID = 43113;
    uint256 constant DOMAIN_APP_ID = 1;
    uint256 constant EPOCH_DURATION = 100;

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
        epochManager.authorizePool(address(pool));
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ── deposit ──────────────────────────────────────────────────

    function test_deposit() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("c"), 1 ether);
        assertTrue(pool.getLatestRoot() != bytes32(0));
    }

    function test_deposit_multiple() public {
        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(keccak256("c1"), 1 ether);
        pool.deposit{value: 2 ether}(keccak256("c2"), 2 ether);
        pool.deposit{value: 0.5 ether}(keccak256("c3"), 0.5 ether);
        vm.stopPrank();
        assertEq(pool.getNextLeafIndex(), 3);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.deposit{value: 0}(keccak256("z"), 0);
    }

    function test_deposit_amount_mismatch_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.deposit{value: 1 ether}(keccak256("mm"), 2 ether);
    }

    function test_deposit_duplicate_commitment_reverts() public {
        bytes32 c = keccak256("dup");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(c, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        pool.deposit{value: 1 ether}(c, 1 ether);
    }

    // ── root history ─────────────────────────────────────────────

    function test_root_history() public {
        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(keccak256("h1"), 1 ether);
        bytes32 r1 = pool.getLatestRoot();
        pool.deposit{value: 1 ether}(keccak256("h2"), 1 ether);
        bytes32 r2 = pool.getLatestRoot();
        vm.stopPrank();
        assertTrue(r1 != r2);
        assertTrue(pool.isKnownRoot(r1));
        assertTrue(pool.isKnownRoot(r2));
    }

    function test_unknown_root() public view {
        assertFalse(pool.isKnownRoot(keccak256("fake")));
    }

    // ── transfer ─────────────────────────────────────────────────

    function test_transfer() public {
        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(keccak256("in1"), 1 ether);
        pool.deposit{value: 1 ether}(keccak256("in2"), 1 ether);
        vm.stopPrank();

        bytes32 root = pool.getLatestRoot();
        vm.prank(alice);
        pool.transfer(
            new bytes(512),
            root,
            [keccak256("n1"), keccak256("n2")],
            [keccak256("o1"), keccak256("o2")],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
        assertTrue(pool.isSpent(keccak256("n1")));
        assertTrue(pool.isSpent(keccak256("n2")));
    }

    function test_transfer_wrong_domain_chain_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("d"), 1 ether);
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.DomainMismatch.selector);
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [keccak256("o1"), keccak256("o2")],
            99999,
            DOMAIN_APP_ID
        );
    }

    function test_transfer_wrong_app_id_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("d"), 1 ether);
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.DomainMismatch.selector);
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [keccak256("o1"), keccak256("o2")],
            DOMAIN_CHAIN_ID,
            999
        );
    }

    function test_transfer_zero_output_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("d"), 1 ether);
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidOutputCommitment.selector);
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [bytes32(0), keccak256("o2")],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
    }

    function test_transfer_duplicate_output_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("d"), 1 ether);
        bytes32 same = keccak256("same");
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidOutputCommitment.selector);
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [same, same],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
    }

    function test_transfer_duplicate_nullifier_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("d"), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("s"), keccak256("s")],
            [keccak256("o1"), keccak256("o2")],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
    }

    function test_transfer_spent_nullifier_reverts() public {
        vm.startPrank(alice);
        pool.deposit{value: 1 ether}(keccak256("in1"), 1 ether);
        pool.deposit{value: 1 ether}(keccak256("in2"), 1 ether);
        vm.stopPrank();

        bytes32 nul = keccak256("reuse");
        vm.prank(alice);
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [nul, keccak256("n2")],
            [keccak256("a1"), keccak256("a2")],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
        vm.prank(alice);
        vm.expectRevert();
        pool.transfer(
            new bytes(512),
            pool.getLatestRoot(),
            [nul, keccak256("n3")],
            [keccak256("b1"), keccak256("b2")],
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID
        );
    }

    // ── withdraw ─────────────────────────────────────────────────

    function test_withdraw() public {
        vm.prank(alice);
        pool.deposit{value: 5 ether}(keccak256("w"), 5 ether);
        uint256 bobBal = bob.balance;
        vm.prank(bob);
        pool.withdraw(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("wn1"), keccak256("wn2")],
            [keccak256("wo1"), keccak256("wo2")],
            payable(bob),
            3 ether
        );
        assertEq(bob.balance, bobBal + 3 ether);
    }

    function test_withdraw_zero_output_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 5 ether}(keccak256("w"), 5 ether);
        vm.prank(bob);
        vm.expectRevert(PrivacyPool.InvalidOutputCommitment.selector);
        pool.withdraw(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [bytes32(0), keccak256("o")],
            payable(bob),
            1 ether
        );
    }

    function test_withdraw_insufficient_reverts() public {
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("c"), 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        pool.withdraw(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("n1"), keccak256("n2")],
            [keccak256("o1"), keccak256("o2")],
            payable(bob),
            10 ether
        );
    }

    function test_withdraw_reentrancy_blocked() public {
        vm.prank(alice);
        pool.deposit{value: 10 ether}(keccak256("re"), 10 ether);
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(pool));
        attacker.attack(
            new bytes(512),
            pool.getLatestRoot(),
            [keccak256("atk1"), keccak256("atk2")],
            [keccak256("ato1"), keccak256("ato2")],
            1 ether
        );
        assertTrue(pool.isSpent(keccak256("atk1")));
        assertFalse(pool.isSpent(keccak256("re-nul1")));
    }

    function test_reclaimExpiredCommit_nonReentrant() public {
        bytes32 commitment = keccak256("cr-c");
        bytes32 salt = keccak256("cr-s");
        bytes32 commitHash = keccak256(abi.encodePacked(commitment, salt));
        vm.prank(alice);
        pool.commitDeposit{value: 1 ether}(commitHash);
        vm.roll(block.number + 101);
        vm.prank(alice);
        pool.reclaimExpiredCommit(commitHash);
    }

    // ── fuzz ─────────────────────────────────────────────────────

    function testFuzz_deposit_amounts(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        bytes32 c = keccak256(abi.encodePacked("fz", amount));
        vm.deal(alice, amount);
        vm.prank(alice);
        pool.deposit{value: amount}(c, amount);
        assertTrue(pool.getLatestRoot() != bytes32(0));
    }

    // ── fixed denominations ──────────────────────────────────────

    function test_fixed_denomination_deposit() public {
        uint256[] memory t = new uint256[](3);
        t[0] = 0.1 ether;
        t[1] = 1 ether;
        t[2] = 10 ether;
        vm.prank(deployer);
        pool.enableFixedDenominations(t);
        vm.prank(alice);
        pool.deposit{value: 1 ether}(keccak256("fd"), 1 ether);
        assertTrue(pool.commitmentExists(keccak256("fd")));
    }

    function test_fixed_denomination_rejects_invalid() public {
        uint256[] memory t = new uint256[](2);
        t[0] = 1 ether;
        t[1] = 10 ether;
        vm.prank(deployer);
        pool.enableFixedDenominations(t);
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidDenomination.selector);
        pool.deposit{value: 0.5 ether}(keccak256("bad"), 0.5 ether);
    }

    function test_fixed_denomination_commit_reveal() public {
        uint256[] memory t = new uint256[](1);
        t[0] = 1 ether;
        vm.prank(deployer);
        pool.enableFixedDenominations(t);
        bytes32 commitment = keccak256("cr-d");
        bytes32 salt = keccak256("salt");
        bytes32 commitHash = keccak256(abi.encodePacked(commitment, salt));
        vm.prank(alice);
        pool.commitDeposit{value: 1 ether}(commitHash);
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.InvalidDenomination.selector);
        pool.commitDeposit{value: 0.5 ether}(keccak256("bad2"));
    }

    function test_disable_fixed_denominations() public {
        uint256[] memory t = new uint256[](1);
        t[0] = 1 ether;
        vm.prank(deployer);
        pool.enableFixedDenominations(t);
        vm.prank(deployer);
        pool.disableFixedDenominations();
        vm.prank(alice);
        pool.deposit{value: 0.5 ether}(keccak256("any"), 0.5 ether);
        assertTrue(pool.commitmentExists(keccak256("any")));
    }

    function test_get_denomination_tiers() public {
        uint256[] memory t = new uint256[](3);
        t[0] = 0.1 ether;
        t[1] = 1 ether;
        t[2] = 10 ether;
        vm.prank(deployer);
        pool.enableFixedDenominations(t);
        uint256[] memory r = pool.getDenominationTiers();
        assertEq(r.length, 3);
        assertEq(r[0], 0.1 ether);
    }

    function test_only_governance_can_set_denominations() public {
        uint256[] memory t = new uint256[](1);
        t[0] = 1 ether;
        vm.prank(alice);
        vm.expectRevert(PrivacyPool.Unauthorized.selector);
        pool.enableFixedDenominations(t);
    }
}
