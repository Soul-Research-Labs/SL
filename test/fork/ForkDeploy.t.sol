// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {IProofVerifier} from "../../contracts/interfaces/IProofVerifier.sol";

/// @dev Mock verifier for fork testing
contract ForkMockVerifier is IProofVerifier {
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

/// @title Fork test: deploy and exercise the privacy pool on an Avalanche Fuji fork.
/// @dev Run with: forge test --fork-url $AVALANCHE_FUJI_RPC_URL --match-contract FujiDeployForkTest
contract FujiDeployForkTest is Test {
    PrivacyPool pool;
    EpochManager em;
    ForkMockVerifier verifier;

    uint256 constant FUJI_CHAIN_ID = 43113;
    uint256 constant APP_ID = 1;

    function setUp() public {
        // Skip if not running on a fork with chain ID 43113
        if (block.chainid != FUJI_CHAIN_ID) {
            return;
        }

        verifier = new ForkMockVerifier();
        em = new EpochManager(3600, FUJI_CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            FUJI_CHAIN_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    /// @dev Deposit on a live fork to verify gas costs and contract interactions
    function test_forkDeposit() public {
        if (block.chainid != FUJI_CHAIN_ID) {
            return; // Skip on non-fork runs
        }
        bytes32 commitment = keccak256("fork_deposit_1");
        vm.deal(address(this), 1 ether);
        pool.deposit{value: 0.1 ether}(commitment, 0.1 ether);
        assertEq(pool.poolBalance(), 0.1 ether);
        assertTrue(pool.getLatestRoot() != bytes32(0));
    }

    /// @dev Verify native AVAX handling on-fork
    function test_forkWithdrawNativeAVAX() public {
        if (block.chainid != FUJI_CHAIN_ID) {
            return;
        }
        bytes32 commitment = keccak256("fork_deposit_2");
        vm.deal(address(this), 1 ether);
        pool.deposit{value: 0.5 ether}(commitment, 0.5 ether);

        address payable recipient = payable(address(0xCAFE));
        bytes32[2] memory nullifiers = [keccak256("fn0"), keccak256("fn1")];
        bytes32[2] memory outputCms = [keccak256("fc0"), keccak256("fc1")];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.withdraw(
            proof,
            pool.getLatestRoot(),
            nullifiers,
            outputCms,
            recipient,
            0.1 ether
        );
        assertEq(recipient.balance, 0.1 ether);
        assertEq(pool.poolBalance(), 0.4 ether);
    }

    /// @dev Epoch finalization on fork
    function test_forkEpochFinalization() public {
        if (block.chainid != FUJI_CHAIN_ID) {
            return;
        }
        vm.warp(block.timestamp + 3601);
        em.finalizeEpoch();
        assertEq(em.currentEpochId(), 1);
    }
}

/// @title Fork test baseline for Moonbase Alpha.
/// @dev Run with: forge test --fork-url $MOONBASE_ALPHA_RPC_URL --match-contract MoonbaseForkTest
contract MoonbaseForkTest is Test {
    uint256 constant MOONBASE_CHAIN_ID = 1287;

    function test_chainIdIsCorrect() public view {
        if (block.chainid != MOONBASE_CHAIN_ID) {
            return;
        }
        assertEq(block.chainid, MOONBASE_CHAIN_ID);
    }
}
