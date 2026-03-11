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

/// @title Fork test for Moonbase Alpha — full pool lifecycle.
/// @dev Run with: forge test --fork-url $MOONBASE_ALPHA_RPC_URL --match-contract MoonbaseForkTest
contract MoonbaseForkTest is Test {
    PrivacyPool pool;
    EpochManager em;
    ForkMockVerifier verifier;

    uint256 constant MOONBASE_CHAIN_ID = 1287;
    uint256 constant APP_ID = 1;

    function setUp() public {
        if (block.chainid != MOONBASE_CHAIN_ID) return;

        verifier = new ForkMockVerifier();
        em = new EpochManager(3600, MOONBASE_CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            MOONBASE_CHAIN_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    function test_chainIdIsCorrect() public view {
        if (block.chainid != MOONBASE_CHAIN_ID) return;
        assertEq(block.chainid, MOONBASE_CHAIN_ID);
    }

    function test_moonbaseDeposit() public {
        if (block.chainid != MOONBASE_CHAIN_ID) return;
        bytes32 commitment = keccak256("moonbase_deposit_1");
        vm.deal(address(this), 1 ether);
        pool.deposit{value: 0.1 ether}(commitment, 0.1 ether);
        assertEq(pool.poolBalance(), 0.1 ether);
        assertTrue(pool.getLatestRoot() != bytes32(0));
    }

    function test_moonbaseMultiDeposit() public {
        if (block.chainid != MOONBASE_CHAIN_ID) return;
        vm.deal(address(this), 10 ether);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 cm = keccak256(abi.encodePacked("moonbase_", i));
            pool.deposit{value: 0.1 ether}(cm, 0.1 ether);
        }
        assertEq(pool.poolBalance(), 0.5 ether);
    }

    function test_moonbaseEpochAndWithdraw() public {
        if (block.chainid != MOONBASE_CHAIN_ID) return;
        bytes32 commitment = keccak256("moonbase_wd_1");
        vm.deal(address(this), 1 ether);
        pool.deposit{value: 0.5 ether}(commitment, 0.5 ether);

        // Advance epoch
        vm.warp(block.timestamp + 3601);
        em.finalizeEpoch();
        assertEq(em.currentEpochId(), 1);

        // Withdraw
        address payable recipient = payable(address(0xBEEF));
        bytes32[2] memory nullifiers = [keccak256("mn0"), keccak256("mn1")];
        bytes32[2] memory outputCms = [keccak256("mc0"), keccak256("mc1")];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.withdraw(
            proof,
            pool.getLatestRoot(),
            nullifiers,
            outputCms,
            recipient,
            0.2 ether
        );
        assertEq(recipient.balance, 0.2 ether);
    }
}

/// @title Fork test for Astar Shibuya.
/// @dev Run with: forge test --fork-url $SHIBUYA_RPC_URL --match-contract ShibuyaForkTest
contract ShibuyaForkTest is Test {
    PrivacyPool pool;
    EpochManager em;
    ForkMockVerifier verifier;

    uint256 constant SHIBUYA_CHAIN_ID = 81;
    uint256 constant APP_ID = 1;

    function setUp() public {
        if (block.chainid != SHIBUYA_CHAIN_ID) return;

        verifier = new ForkMockVerifier();
        em = new EpochManager(3600, SHIBUYA_CHAIN_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            SHIBUYA_CHAIN_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    function test_shibuyaChainId() public view {
        if (block.chainid != SHIBUYA_CHAIN_ID) return;
        assertEq(block.chainid, SHIBUYA_CHAIN_ID);
    }

    function test_shibuyaDeposit() public {
        if (block.chainid != SHIBUYA_CHAIN_ID) return;
        bytes32 commitment = keccak256("shibuya_deposit_1");
        vm.deal(address(this), 1 ether);
        pool.deposit{value: 0.1 ether}(commitment, 0.1 ether);
        assertEq(pool.poolBalance(), 0.1 ether);
    }

    function test_shibuyaFullCycle() public {
        if (block.chainid != SHIBUYA_CHAIN_ID) return;
        vm.deal(address(this), 10 ether);

        // Deposit
        bytes32 cm = keccak256("shibuya_cycle");
        pool.deposit{value: 1 ether}(cm, 1 ether);

        // Epoch
        vm.warp(block.timestamp + 3601);
        em.finalizeEpoch();

        // Withdraw
        address payable recipient = payable(address(0xFACE));
        bytes32[2] memory nullifiers = [keccak256("sn0"), keccak256("sn1")];
        bytes32[2] memory outputCms = [keccak256("sc0"), keccak256("sc1")];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.withdraw(
            proof,
            pool.getLatestRoot(),
            nullifiers,
            outputCms,
            recipient,
            0.5 ether
        );
        assertEq(recipient.balance, 0.5 ether);
        assertEq(pool.poolBalance(), 0.5 ether);
    }
}

/// @title Fork test for Evmos Testnet.
/// @dev Run with: forge test --fork-url $EVMOS_TESTNET_RPC_URL --match-contract EvmosForkTest
contract EvmosForkTest is Test {
    PrivacyPool pool;
    EpochManager em;
    ForkMockVerifier verifier;

    uint256 constant EVMOS_TESTNET_ID = 9000;
    uint256 constant APP_ID = 1;

    function setUp() public {
        if (block.chainid != EVMOS_TESTNET_ID) return;

        verifier = new ForkMockVerifier();
        em = new EpochManager(3600, EVMOS_TESTNET_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            EVMOS_TESTNET_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    function test_evmosChainId() public view {
        if (block.chainid != EVMOS_TESTNET_ID) return;
        assertEq(block.chainid, EVMOS_TESTNET_ID);
    }

    function test_evmosDeposit() public {
        if (block.chainid != EVMOS_TESTNET_ID) return;
        vm.deal(address(this), 1 ether);
        bytes32 cm = keccak256("evmos_dep_1");
        pool.deposit{value: 0.25 ether}(cm, 0.25 ether);
        assertEq(pool.poolBalance(), 0.25 ether);
    }

    function test_evmosEpochProgression() public {
        if (block.chainid != EVMOS_TESTNET_ID) return;

        // Multiple epochs
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 3601);
            em.finalizeEpoch();
        }
        assertEq(em.currentEpochId(), 3);
    }
}

/// @title Fork test for Aurora Testnet.
/// @dev Run with: forge test --fork-url $AURORA_TESTNET_RPC_URL --match-contract AuroraForkTest
contract AuroraForkTest is Test {
    PrivacyPool pool;
    EpochManager em;
    ForkMockVerifier verifier;

    uint256 constant AURORA_TESTNET_ID = 1313161555;
    uint256 constant APP_ID = 1;

    function setUp() public {
        if (block.chainid != AURORA_TESTNET_ID) return;

        verifier = new ForkMockVerifier();
        em = new EpochManager(3600, AURORA_TESTNET_ID);
        pool = new PrivacyPool(
            address(verifier),
            address(em),
            AURORA_TESTNET_ID,
            APP_ID,
            address(this),
            address(0)
        );
        em.authorizePool(address(pool));
    }

    function test_auroraChainId() public view {
        if (block.chainid != AURORA_TESTNET_ID) return;
        assertEq(block.chainid, AURORA_TESTNET_ID);
    }

    function test_auroraDepositAndWithdraw() public {
        if (block.chainid != AURORA_TESTNET_ID) return;
        vm.deal(address(this), 5 ether);

        bytes32 cm = keccak256("aurora_dep");
        pool.deposit{value: 1 ether}(cm, 1 ether);

        address payable recipient = payable(address(0xDEAD));
        bytes32[2] memory nullifiers = [keccak256("an0"), keccak256("an1")];
        bytes32[2] memory outputCms = [keccak256("ac0"), keccak256("ac1")];
        bytes memory proof = new bytes(768);
        proof[0] = 0x01;

        pool.withdraw(
            proof,
            pool.getLatestRoot(),
            nullifiers,
            outputCms,
            recipient,
            0.3 ether
        );
        assertEq(recipient.balance, 0.3 ether);
    }
}
