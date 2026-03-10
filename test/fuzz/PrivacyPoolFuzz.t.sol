// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {IProofVerifier} from "../../contracts/interfaces/IProofVerifier.sol";

/// @dev Mock that always returns true — isolates fuzz testing to pool logic.
contract FuzzMockVerifier is IProofVerifier {
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

contract PrivacyPoolFuzzTest is Test {
    PrivacyPool pool;
    EpochManager em;
    FuzzMockVerifier verifier;

    uint256 constant CHAIN_ID = 43113;
    uint256 constant APP_ID = 1;

    function setUp() public {
        verifier = new FuzzMockVerifier();
        em = new EpochManager(100, CHAIN_ID);
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

    /// Any non-zero deposit with matching value should succeed.
    function testFuzz_deposit(bytes32 commitment, uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        vm.assume(commitment != bytes32(0));
        vm.deal(address(this), amount);
        pool.deposit{value: amount}(commitment, amount);
        assertTrue(pool.commitmentExists(commitment));
    }

    /// Depositing zero should revert.
    function testFuzz_depositZeroReverts(bytes32 commitment) public {
        vm.assume(commitment != bytes32(0));
        vm.expectRevert();
        pool.deposit{value: 0}(commitment, 0);
    }

    /// Duplicate commitment deposits should revert.
    function testFuzz_duplicateCommitmentReverts(
        bytes32 commitment,
        uint256 amount
    ) public {
        amount = bound(amount, 1, 1 ether);
        vm.assume(commitment != bytes32(0));
        vm.deal(address(this), amount * 2);
        pool.deposit{value: amount}(commitment, amount);
        vm.expectRevert();
        pool.deposit{value: amount}(commitment, amount);
    }

    /// Pool balance invariant: after N deposits, poolBalance == sum(amounts).
    function testFuzz_poolBalanceInvariant(uint256 a1, uint256 a2) public {
        a1 = bound(a1, 1, 5 ether);
        a2 = bound(a2, 1, 5 ether);
        bytes32 c1 = keccak256(abi.encodePacked("c1", a1));
        bytes32 c2 = keccak256(abi.encodePacked("c2", a2));

        vm.deal(address(this), a1 + a2);
        pool.deposit{value: a1}(c1, a1);
        pool.deposit{value: a2}(c2, a2);

        assertEq(pool.poolBalance(), a1 + a2);
    }
}
