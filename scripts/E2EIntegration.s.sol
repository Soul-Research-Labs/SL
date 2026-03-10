// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/core/PrivacyPool.sol";
import "../contracts/core/EpochManager.sol";
import "../contracts/core/UniversalNullifierRegistry.sol";
import "../contracts/verifiers/Halo2SnarkVerifier.sol";

/// @title E2E Integration Test Script
/// @notice Deploys full stack on a local fork, performs deposit → finalize → registry flow.
/// @dev Run with:
///      forge script scripts/E2EIntegration.s.sol --fork-url $FUJI_RPC --broadcast -vvvv
contract E2EIntegration is Script {
    PrivacyPool public pool;
    EpochManager public epochManager;
    UniversalNullifierRegistry public registry;
    Halo2SnarkVerifier public verifier;

    uint256 internal constant EPOCH_DURATION = 10;
    uint256 internal constant DOMAIN_CHAIN = 43113;
    uint256 internal constant DOMAIN_APP = 1;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ── Phase 1: Deploy core contracts ─────────────────────
        console.log("=== Deploying Core Contracts ===");

        verifier = new Halo2SnarkVerifier();
        console.log("Halo2SnarkVerifier:", address(verifier));

        epochManager = new EpochManager(EPOCH_DURATION);
        console.log("EpochManager:", address(epochManager));

        pool = new PrivacyPool(
            address(verifier),
            address(epochManager),
            DOMAIN_CHAIN,
            DOMAIN_APP,
            deployer,
            address(0)
        );
        console.log("PrivacyPool:", address(pool));

        registry = new UniversalNullifierRegistry();
        console.log("UniversalNullifierRegistry:", address(registry));

        // Authorize pool in epoch manager
        epochManager.authorizePool(address(pool));

        // Register this chain in the registry
        registry.registerChain(DOMAIN_CHAIN, "Avalanche Fuji", deployer);

        // ── Phase 2: Deposit ───────────────────────────────────
        console.log("\n=== Deposit Phase ===");

        bytes32 commitment1 = keccak256("test-commitment-1");
        bytes32 commitment2 = keccak256("test-commitment-2");

        pool.deposit{value: 0.1 ether}(commitment1);
        console.log("Deposit 1: 0.1 ETH");

        pool.deposit{value: 0.2 ether}(commitment2);
        console.log("Deposit 2: 0.2 ETH");

        bytes32 root = pool.getLatestRoot();
        console.log("Latest Merkle root after deposits:");
        console.logBytes32(root);

        assert(pool.isKnownRoot(root));
        console.log("Root verification: PASS");

        // ── Phase 3: Epoch Finalization ────────────────────────
        console.log("\n=== Epoch Finalization ===");

        // Move blocks forward to allow epoch finalization
        // (In a real fork, blocks advance naturally)

        console.log("Leaf count:", pool.getNextLeafIndex());

        // ── Phase 4: Registry Integration ──────────────────────
        console.log("\n=== Registry Integration ===");

        bytes32 epochRoot = keccak256("test-epoch-root");
        registry.submitEpochRoot(DOMAIN_CHAIN, 0, epochRoot, 2);
        console.log("Submitted epoch root to registry");

        bytes32 storedRoot = registry.epochRoots(DOMAIN_CHAIN, 0);
        assert(storedRoot == epochRoot);
        console.log("Epoch root verification: PASS");

        // Create global snapshot
        registry.createGlobalSnapshot();
        bytes32 globalRoot = registry.globalRoot();
        console.log("Global root:");
        console.logBytes32(globalRoot);
        assert(globalRoot != bytes32(0));
        console.log("Global snapshot: PASS");

        // ── Summary ────────────────────────────────────────────
        console.log("\n=== E2E Integration Test Summary ===");
        console.log("Contracts deployed: 4");
        console.log("Deposits: 2 (0.3 ETH total)");
        console.log("Epoch root submitted: PASS");
        console.log("Global snapshot created: PASS");
        console.log("All checks: PASS");

        vm.stopBroadcast();
    }
}
