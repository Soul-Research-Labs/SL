// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {GovernanceTimelock} from "../../contracts/core/GovernanceTimelock.sol";
import {IProofVerifier} from "../../contracts/interfaces/IProofVerifier.sol";

contract IntegrationMockVerifier is IProofVerifier {
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

/// @title Integration test: full deposit → transfer → withdraw lifecycle
contract DepositTransferWithdrawTest is Test {
    PrivacyPool pool;
    EpochManager em;
    IntegrationMockVerifier verifier;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address governance;

    uint256 constant CHAIN_ID = 43113;
    uint256 constant APP_ID = 1;

    function setUp() public {
        governance = address(this);
        verifier = new IntegrationMockVerifier();
        em = new EpochManager(100, CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            CHAIN_ID,
            APP_ID,
            governance,
            address(0)
        );
        em.authorizePool(address(pool));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /// Full lifecycle: deposit → verify state → transfer → verify nullifiers
    function test_depositAndTransfer() public {
        // === Deposit ===
        bytes32 commitment = keccak256("note1");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(commitment, 1 ether);

        // Verify deposit state
        assertEq(pool.poolBalance(), 1 ether);
        assertTrue(pool.commitmentExists(commitment));
        assertEq(pool.getNextLeafIndex(), 1);
        assertTrue(pool.getLatestRoot() != bytes32(0));

        // === Transfer (mock proof) ===
        bytes32 root = pool.getLatestRoot();
        assertTrue(pool.isKnownRoot(root));

        bytes32[2] memory nullifiers = [keccak256("nul0"), keccak256("nul1")];
        bytes32[2] memory outputCms = [keccak256("out0"), keccak256("out1")];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.transfer(proof, root, nullifiers, outputCms, CHAIN_ID, APP_ID);

        // Verify transfer state
        assertTrue(pool.isSpent(nullifiers[0]));
        assertTrue(pool.isSpent(nullifiers[1]));
        // Transfer outputs are inserted into the Merkle tree but not tracked in commitmentExists
        assertEq(pool.getNextLeafIndex(), 3); // 1 deposit + 2 transfer outputs
        // Pool balance unchanged after transfer (no value leaves)
        assertEq(pool.poolBalance(), 1 ether);
    }

    /// Deposit → withdraw → verify funds moved to recipient
    function test_depositAndWithdraw() public {
        bytes32 commitment = keccak256("note_withdraw");
        vm.prank(alice);
        pool.deposit{value: 2 ether}(commitment, 2 ether);

        bytes32 root = pool.getLatestRoot();
        bytes32[2] memory nullifiers = [keccak256("wnul0"), keccak256("wnul1")];
        bytes32[2] memory outputCms = [
            keccak256("change0"),
            keccak256("change1")
        ];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        uint256 bobBefore = bob.balance;
        pool.withdraw(
            proof,
            root,
            nullifiers,
            outputCms,
            payable(bob),
            1 ether
        );

        // Verify withdrawal
        assertEq(bob.balance, bobBefore + 1 ether);
        assertEq(pool.poolBalance(), 1 ether); // 2 - 1 = 1
        assertTrue(pool.isSpent(nullifiers[0]));
    }

    /// Double-spend protection: same nullifier cannot be used twice
    function test_doubleSpendReverts() public {
        bytes32 c1 = keccak256("ds_note1");
        bytes32 c2 = keccak256("ds_note2");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(c1, 1 ether);
        vm.prank(alice);
        pool.deposit{value: 1 ether}(c2, 1 ether);

        bytes32 root = pool.getLatestRoot();
        bytes32[2] memory nullifiers = [
            keccak256("ds_nul0"),
            keccak256("ds_nul1")
        ];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.transfer(
            proof,
            root,
            nullifiers,
            [keccak256("o1"), keccak256("o2")],
            CHAIN_ID,
            APP_ID
        );

        // Second transfer with same nullifiers should revert
        root = pool.getLatestRoot();
        vm.expectRevert();
        pool.transfer(
            proof,
            root,
            nullifiers,
            [keccak256("o3"), keccak256("o4")],
            CHAIN_ID,
            APP_ID
        );
    }
}

/// @title Integration test: EpochManager cross-chain epoch root flow
contract EpochCrossChainTest is Test {
    EpochManager em;
    address pool = address(0xAA);
    address bridge = address(0xBB);

    function setUp() public {
        em = new EpochManager(100, 43113);
        em.authorizePool(pool);
        em.authorizeBridge(bridge);
    }

    /// Full epoch lifecycle: register nullifiers → finalize → receive remote
    function test_epochLifecycle() public {
        // Register nullifiers from pool
        vm.startPrank(pool);
        em.registerNullifier(keccak256("n1"));
        em.registerNullifier(keccak256("n2"));
        vm.stopPrank();

        // Start new epoch (auto-finalizes current)
        vm.warp(block.timestamp + 101);
        em.startNewEpoch();

        // Verify epoch advanced
        assertEq(em.currentEpochId(), 1);
        assertTrue(em.isNullifierSpentGlobal(keccak256("n1")));

        // Receive remote epoch root from Moonbeam
        bytes32 remoteRoot = keccak256("moonbeam_epoch_0");
        vm.prank(bridge);
        em.receiveRemoteEpochRoot(1284, 0, remoteRoot);
        assertEq(em.getRemoteEpochRoot(1284, 0), remoteRoot);
    }

    /// Multi-chain epoch sync: Avalanche → Moonbeam → Astar
    function test_multiChainEpochSync() public {
        // Register nullifiers on "Avalanche" side
        vm.startPrank(pool);
        em.registerNullifier(keccak256("avax_n1"));
        em.registerNullifier(keccak256("avax_n2"));
        em.registerNullifier(keccak256("avax_n3"));
        vm.stopPrank();

        // Start new epoch (auto-finalizes current)
        vm.warp(block.timestamp + 101);
        em.startNewEpoch();

        // Receive Moonbeam epoch root (chain 1284)
        bytes32 moonbeamRoot = keccak256("moonbeam_epoch_0_root");
        vm.prank(bridge);
        em.receiveRemoteEpochRoot(1284, 0, moonbeamRoot);

        // Receive Astar epoch root (chain 592)
        bytes32 astarRoot = keccak256("astar_epoch_0_root");
        vm.prank(bridge);
        em.receiveRemoteEpochRoot(592, 0, astarRoot);

        // Verify all roots stored
        assertEq(em.getRemoteEpochRoot(1284, 0), moonbeamRoot);
        assertEq(em.getRemoteEpochRoot(592, 0), astarRoot);
        assertEq(em.currentEpochId(), 1);

        // Register more nullifiers in epoch 1
        vm.startPrank(pool);
        em.registerNullifier(keccak256("avax_n4"));
        vm.stopPrank();

        // Start epoch 2 (auto-finalizes epoch 1)
        vm.warp(block.timestamp + 202);
        em.startNewEpoch();
        assertEq(em.currentEpochId(), 2);

        // Receive epoch 1 roots from other chains
        vm.startPrank(bridge);
        em.receiveRemoteEpochRoot(1284, 1, keccak256("moonbeam_epoch_1"));
        em.receiveRemoteEpochRoot(592, 1, keccak256("astar_epoch_1"));
        vm.stopPrank();
    }

    /// Verify unauthorized bridge cannot submit epoch roots
    function test_unauthorizedBridgeReverts() public {
        address fakeBridge = address(0xDEAD);
        bytes32 fakeRoot = keccak256("fake");

        vm.prank(fakeBridge);
        vm.expectRevert();
        em.receiveRemoteEpochRoot(1284, 0, fakeRoot);
    }

    /// Zero root submissions should be rejected
    function test_zeroRootRejected() public {
        vm.prank(bridge);
        vm.expectRevert();
        em.receiveRemoteEpochRoot(1284, 0, bytes32(0));
    }
}

/// @title Integration test: full multi-deposit batch with epoch finalization
contract BatchDepositEpochTest is Test {
    PrivacyPool pool;
    EpochManager em;
    IntegrationMockVerifier verifier;

    uint256 constant CHAIN_ID = 43113;
    uint256 constant APP_ID = 1;

    function setUp() public {
        verifier = new IntegrationMockVerifier();
        em = new EpochManager(50, CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            CHAIN_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    /// Multiple users depositing, then transfers, then withdrawals across
    /// epoch boundaries — verifying pool balance invariant.
    function test_multiUserLifecycle() public {
        address[3] memory users = [
            address(0x1001),
            address(0x1002),
            address(0x1003)
        ];

        // Fund users
        for (uint256 i = 0; i < 3; i++) {
            vm.deal(users[i], 10 ether);
        }

        // === Epoch 0: Multiple deposits ===
        uint256 totalDeposited = 0;
        for (uint256 i = 0; i < 3; i++) {
            bytes32 commitment = keccak256(abi.encodePacked("deposit", i));
            uint256 amount = (i + 1) * 1 ether;
            vm.prank(users[i]);
            pool.deposit{value: amount}(commitment, amount);
            totalDeposited += amount;
        }

        // Verify pool balance = sum of deposits
        assertEq(pool.poolBalance(), totalDeposited);
        assertEq(pool.getNextLeafIndex(), 3);

        // === Finalize epoch 0 ===
        vm.warp(block.timestamp + 51);
        em.finalizeEpoch();

        // === Epoch 1: Transfer ===
        bytes32 root = pool.getLatestRoot();
        bytes32[2] memory tNullifiers = [
            keccak256("batch_tn0"),
            keccak256("batch_tn1")
        ];
        bytes32[2] memory tOutputs = [
            keccak256("batch_to0"),
            keccak256("batch_to1")
        ];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.transfer(proof, root, tNullifiers, tOutputs, CHAIN_ID, APP_ID);

        // Pool balance unchanged (no value leaves in transfer)
        assertEq(pool.poolBalance(), totalDeposited);

        // === Epoch 1: Withdrawal ===
        root = pool.getLatestRoot();
        bytes32[2] memory wNullifiers = [
            keccak256("batch_wn0"),
            keccak256("batch_wn1")
        ];
        bytes32[2] memory wOutputs = [
            keccak256("batch_wo0"),
            keccak256("batch_wo1")
        ];

        address payable recipient = payable(address(0x9999));
        uint256 withdrawAmount = 2 ether;
        uint256 recipientBefore = recipient.balance;

        pool.withdraw(
            proof,
            root,
            wNullifiers,
            wOutputs,
            recipient,
            withdrawAmount
        );

        assertEq(recipient.balance, recipientBefore + withdrawAmount);
        assertEq(pool.poolBalance(), totalDeposited - withdrawAmount);
    }
}
