// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/core/PrivacyPool.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";
import "../contracts/interfaces/IProofVerifier.sol";

/// @notice Mock verifier for benchmarking (always returns true)
contract BenchmarkVerifier is IProofVerifier {
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
        return "benchmark";
    }
}

/// @title Gas Benchmark Suite
/// @notice Measures gas costs for all critical operations.
/// @dev Run: forge test --match-contract GasBenchmark -vvv --gas-report
contract GasBenchmark is Test {
    PrivacyPool public pool;
    EpochManager public epochManager;
    UniversalNullifierRegistry public registry;
    BenchmarkVerifier public verifier;

    address public deployer = address(1);
    address public alice = address(2);

    function setUp() public {
        vm.startPrank(deployer);
        verifier = new BenchmarkVerifier();
        epochManager = new EpochManager(100);
        pool = new PrivacyPool(
            address(verifier),
            address(epochManager),
            43113,
            1,
            deployer,
            address(0)
        );
        epochManager.authorizePool(address(pool));
        registry = new UniversalNullifierRegistry();
        vm.stopPrank();

        vm.deal(alice, 1000 ether);
    }

    // ── Privacy Pool Benchmarks ────────────────────────────────

    function test_gas_deposit() public {
        bytes32 commitment = keccak256("benchmark-deposit");
        vm.prank(alice);
        pool.deposit{value: 1 ether}(commitment);
    }

    function test_gas_deposit_10_sequential() public {
        vm.startPrank(alice);
        for (uint256 i = 0; i < 10; i++) {
            pool.deposit{value: 0.1 ether}(
                keccak256(abi.encodePacked("deposit", i))
            );
        }
        vm.stopPrank();
    }

    function test_gas_transfer() public {
        // Set up 2 deposits first
        vm.startPrank(alice);
        bytes32 c1 = keccak256("c1");
        bytes32 c2 = keccak256("c2");
        pool.deposit{value: 1 ether}(c1);
        pool.deposit{value: 1 ether}(c2);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul1 = keccak256("nul1");
        bytes32 nul2 = keccak256("nul2");
        bytes32 out1 = keccak256("out1");
        bytes32 out2 = keccak256("out2");

        bytes memory proof = new bytes(512);

        // Measure transfer gas
        pool.transfer(proof, root, [nul1, nul2], [out1, out2]);
        vm.stopPrank();
    }

    function test_gas_withdraw() public {
        vm.startPrank(alice);
        bytes32 c1 = keccak256("w-c1");
        bytes32 c2 = keccak256("w-c2");
        pool.deposit{value: 2 ether}(c1);
        pool.deposit{value: 2 ether}(c2);

        bytes32 root = pool.getLatestRoot();
        bytes32 nul1 = keccak256("w-nul1");
        bytes32 nul2 = keccak256("w-nul2");
        bytes32 out1 = keccak256("w-out1");
        bytes32 out2 = keccak256("w-out2");

        bytes memory proof = new bytes(512);

        pool.withdraw(proof, root, [nul1, nul2], [out1, out2], alice, 1 ether);
        vm.stopPrank();
    }

    function test_gas_root_check() public view {
        pool.isKnownRoot(bytes32(uint256(1)));
    }

    function test_gas_nullifier_check() public view {
        pool.isSpent(bytes32(uint256(1)));
    }

    // ── Universal Nullifier Registry Benchmarks ────────────────

    function test_gas_registerChain() public {
        vm.prank(deployer);
        registry.registerChain(43114, "Avalanche", address(this));
    }

    function test_gas_submitEpochRoot() public {
        vm.prank(deployer);
        registry.registerChain(43114, "Avalanche", address(this));

        registry.submitEpochRoot(43114, 0, keccak256("root-0"), 100);
    }

    function test_gas_submitEpochRoot_sequential_10() public {
        vm.prank(deployer);
        registry.registerChain(43114, "Avalanche", address(this));

        for (uint256 i = 0; i < 10; i++) {
            registry.submitEpochRoot(
                43114,
                i,
                keccak256(abi.encodePacked("root", i)),
                uint32(i * 10)
            );
        }
    }

    function test_gas_createGlobalSnapshot_3_chains() public {
        vm.startPrank(deployer);
        registry.registerChain(43114, "Avalanche", address(this));
        registry.registerChain(1284, "Moonbeam", address(this));
        registry.registerChain(592, "Astar", address(this));
        vm.stopPrank();

        registry.submitEpochRoot(43114, 0, keccak256("avax"), 10);
        registry.submitEpochRoot(1284, 0, keccak256("moon"), 20);
        registry.submitEpochRoot(592, 0, keccak256("astar"), 30);

        vm.prank(deployer);
        registry.createGlobalSnapshot();
    }

    function test_gas_isNullifierSpentGlobally_3_chains() public {
        vm.startPrank(deployer);
        registry.registerChain(43114, "Avalanche", address(this));
        registry.registerChain(1284, "Moonbeam", address(this));
        registry.registerChain(592, "Astar", address(this));
        vm.stopPrank();

        // Check nullifier across 3 chains (not spent)
        registry.isNullifierSpentGlobally(keccak256("test-nullifier"));
    }

    // ── EpochManager Benchmarks ────────────────────────────────

    function test_gas_epochManager_deploy() public {
        new EpochManager(100);
    }
}
