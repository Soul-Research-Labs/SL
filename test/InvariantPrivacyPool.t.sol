// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/PrivacyPool.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";
import "../contracts/interfaces/IProofVerifier.sol";

/// @notice Always-true verifier for invariant testing
contract InvariantMockVerifier is IProofVerifier {
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

/// @title PrivacyPoolHandler — Guided actions for invariant testing
/// @dev Foundry calls random functions on this handler during invariant runs.
///      The handler tracks ghost variables to compare against actual contract state.
contract PrivacyPoolHandler is Test {
    PrivacyPool public pool;

    // Ghost variables
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_commitmentCount;
    uint256 public ghost_nullifierCount;

    // Track commitments to avoid duplicates
    mapping(bytes32 => bool) public usedCommitments;
    bytes32[] public commitments;

    // Track nullifier pairs for transfers/withdrawals
    uint256 public nextNullifierSeed;

    constructor(PrivacyPool _pool) {
        pool = _pool;
    }

    /// @notice Deposit a random amount with a unique commitment
    function deposit(uint256 amount, uint256 commitmentSeed) external {
        // Bound amount to reasonable range (0.001 — 100 ETH)
        amount = bound(amount, 1e15, 100 ether);

        // Generate unique commitment from seed
        bytes32 commitment = keccak256(
            abi.encodePacked(commitmentSeed, ghost_commitmentCount)
        );
        if (usedCommitments[commitment]) return;

        usedCommitments[commitment] = true;
        commitments.push(commitment);

        deal(address(this), amount);
        pool.deposit{value: amount}(commitment, amount);

        ghost_totalDeposited += amount;
        ghost_commitmentCount++;
    }

    /// @notice Execute a transfer (needs existing root + unique nullifiers)
    function transfer(uint256 nullifierSeed) external {
        if (commitments.length < 1) return;

        bytes32 merkleRoot = pool.getLatestRoot();

        bytes32 nul0 = keccak256(
            abi.encodePacked("nul0", nextNullifierSeed, nullifierSeed)
        );
        bytes32 nul1 = keccak256(
            abi.encodePacked("nul1", nextNullifierSeed, nullifierSeed)
        );

        if (pool.isSpent(nul0) || pool.isSpent(nul1)) return;

        bytes32 out0 = keccak256(abi.encodePacked("out0", nextNullifierSeed));
        bytes32 out1 = keccak256(abi.encodePacked("out1", nextNullifierSeed));

        if (pool.commitmentExists(out0) || pool.commitmentExists(out1)) return;

        nextNullifierSeed++;

        bytes memory proof = hex"01";
        pool.transfer(
            proof,
            merkleRoot,
            [nul0, nul1],
            [out0, out1],
            pool.domainChainId(),
            pool.domainAppId()
        );

        ghost_nullifierCount += 2;
        ghost_commitmentCount += 2;
    }

    /// @notice Withdraw a bounded amount
    function withdraw(uint256 exitValue, uint256 nullifierSeed) external {
        if (pool.poolBalance() == 0) return;

        exitValue = bound(exitValue, 1, pool.poolBalance());

        bytes32 merkleRoot = pool.getLatestRoot();

        bytes32 nul0 = keccak256(
            abi.encodePacked("wnul0", nextNullifierSeed, nullifierSeed)
        );
        bytes32 nul1 = keccak256(
            abi.encodePacked("wnul1", nextNullifierSeed, nullifierSeed)
        );

        if (pool.isSpent(nul0) || pool.isSpent(nul1)) return;

        bytes32 out0 = keccak256(abi.encodePacked("wout0", nextNullifierSeed));
        bytes32 out1 = keccak256(abi.encodePacked("wout1", nextNullifierSeed));

        if (pool.commitmentExists(out0) || pool.commitmentExists(out1)) return;

        nextNullifierSeed++;

        bytes memory proof = hex"01";
        pool.withdraw(
            proof,
            merkleRoot,
            [nul0, nul1],
            [out0, out1],
            payable(address(0xBEEF)),
            exitValue
        );

        ghost_totalWithdrawn += exitValue;
        ghost_nullifierCount += 2;
        ghost_commitmentCount += 2;
    }

    receive() external payable {}
}

/// @title InvariantPrivacyPool — Core invariant tests for the privacy pool
contract InvariantPrivacyPool is Test {
    PrivacyPool public pool;
    EpochManager public epochManager;
    PrivacyPoolHandler public handler;
    InvariantMockVerifier public verifier;

    function setUp() public {
        verifier = new InvariantMockVerifier();
        epochManager = new EpochManager(300);
        pool = new PrivacyPool(
            address(verifier),
            address(epochManager),
            43113,
            1,
            address(this),
            address(0)
        );
        handler = new PrivacyPoolHandler(pool);

        // Fund the handler for deposits
        deal(address(handler), 10000 ether);

        // Target only the handler for invariant calls
        targetContract(address(handler));
    }

    // ── Invariant: Pool balance == total deposited - total withdrawn ──

    function invariant_poolBalanceConservation() public view {
        assertEq(
            pool.poolBalance(),
            handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn(),
            "Pool balance must equal deposits minus withdrawals"
        );
    }

    // ── Invariant: Contract ETH balance >= pool balance ──

    function invariant_contractSolvency() public view {
        assertGe(
            address(pool).balance,
            pool.poolBalance(),
            "Contract must hold at least poolBalance in ETH"
        );
    }

    // ── Invariant: Leaf index is monotonically increasing ──

    function invariant_leafIndexMonotonic() public view {
        assertEq(
            pool.getNextLeafIndex(),
            handler.ghost_commitmentCount(),
            "Leaf index must equal total commitments inserted"
        );
    }

    // ── Invariant: Pool balance is never negative ──

    function invariant_poolBalanceNonNegative() public view {
        // Solidity uint256 can't be negative, but we verify the accounting
        assertGe(
            handler.ghost_totalDeposited(),
            handler.ghost_totalWithdrawn(),
            "Total deposited must be >= total withdrawn"
        );
    }
}

/// @title FuzzPrivacyPool — Fuzz tests for individual functions
contract FuzzPrivacyPool is Test {
    PrivacyPool public pool;
    EpochManager public epochManager;
    InvariantMockVerifier public verifier;

    function setUp() public {
        verifier = new InvariantMockVerifier();
        epochManager = new EpochManager(300);
        pool = new PrivacyPool(
            address(verifier),
            address(epochManager),
            43113,
            1,
            address(this),
            address(0)
        );
    }

    /// @notice Fuzz deposit: any amount > 0 should succeed with matching msg.value
    function testFuzz_deposit(bytes32 commitment, uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.assume(commitment != bytes32(0));

        deal(address(this), amount);
        pool.deposit{value: amount}(commitment, amount);

        assertEq(pool.poolBalance(), amount);
        assertTrue(pool.commitmentExists(commitment));
        assertEq(pool.getNextLeafIndex(), 1);
    }

    /// @notice Fuzz: deposit with zero amount always reverts
    function testFuzz_depositZeroReverts(bytes32 commitment) public {
        vm.expectRevert(PrivacyPool.InvalidDeposit.selector);
        pool.deposit{value: 0}(commitment, 0);
    }

    /// @notice Fuzz: duplicate commitment always reverts
    function testFuzz_duplicateCommitmentReverts(
        bytes32 commitment,
        uint256 amount
    ) public {
        amount = bound(amount, 1, 100 ether);
        vm.assume(commitment != bytes32(0));

        deal(address(this), amount * 2);
        pool.deposit{value: amount}(commitment, amount);

        vm.expectRevert(PrivacyPool.CommitmentAlreadyExists.selector);
        pool.deposit{value: amount}(commitment, amount);
    }

    /// @notice Fuzz: nullifier can only be spent once
    function testFuzz_nullifierSpentOnce(uint256 seed) public {
        // Deposit to get a valid root
        bytes32 cm = keccak256(abi.encodePacked(seed));
        deal(address(this), 1 ether);
        pool.deposit{value: 1 ether}(cm, 1 ether);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul0 = keccak256(abi.encodePacked("n0", seed));
        bytes32 nul1 = keccak256(abi.encodePacked("n1", seed));
        bytes32 out0 = keccak256(abi.encodePacked("o0", seed));
        bytes32 out1 = keccak256(abi.encodePacked("o1", seed));

        pool.transfer(hex"01", root, [nul0, nul1], [out0, out1], 43113, 1);

        assertTrue(pool.isSpent(nul0));
        assertTrue(pool.isSpent(nul1));

        // Second transfer with same nullifiers must revert
        bytes32 out2 = keccak256(abi.encodePacked("o2", seed));
        bytes32 out3 = keccak256(abi.encodePacked("o3", seed));
        bytes32 newRoot = pool.getLatestRoot();

        vm.expectRevert(
            abi.encodeWithSelector(
                PrivacyPool.NullifierAlreadySpent.selector,
                nul0
            )
        );
        pool.transfer(hex"01", newRoot, [nul0, nul1], [out2, out3], 43113, 1);
    }

    /// @notice Fuzz: withdrawal amount cannot exceed pool balance
    function testFuzz_withdrawExceedsBalance(
        uint256 depositAmt,
        uint256 withdrawAmt
    ) public {
        depositAmt = bound(depositAmt, 1, 50 ether);
        withdrawAmt = bound(withdrawAmt, depositAmt + 1, type(uint128).max);

        bytes32 cm = keccak256(abi.encodePacked(depositAmt, withdrawAmt));
        deal(address(this), depositAmt);
        pool.deposit{value: depositAmt}(cm, depositAmt);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul0 = keccak256(abi.encodePacked("wn0", withdrawAmt));
        bytes32 nul1 = keccak256(abi.encodePacked("wn1", withdrawAmt));
        bytes32 out0 = keccak256(abi.encodePacked("wo0", withdrawAmt));
        bytes32 out1 = keccak256(abi.encodePacked("wo1", withdrawAmt));

        vm.expectRevert(PrivacyPool.InsufficientPoolBalance.selector);
        pool.withdraw(
            hex"01",
            root,
            [nul0, nul1],
            [out0, out1],
            payable(address(0xBEEF)),
            withdrawAmt
        );
    }

    /// @notice Fuzz: multiple sequential deposits remain consistent
    function testFuzz_sequentialDeposits(uint8 count) public {
        count = uint8(bound(count, 1, 20));
        uint256 totalDeposited = 0;

        for (uint256 i = 0; i < count; i++) {
            bytes32 cm = keccak256(abi.encodePacked("seq", i));
            uint256 amt = 0.1 ether;
            deal(address(this), amt);
            pool.deposit{value: amt}(cm, amt);
            totalDeposited += amt;
        }

        assertEq(pool.poolBalance(), totalDeposited);
        assertEq(pool.getNextLeafIndex(), count);
    }

    receive() external payable {}
}
