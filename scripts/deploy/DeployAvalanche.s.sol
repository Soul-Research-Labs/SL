// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {AvaxWarpAdapter} from "../../contracts/bridges/AvaxWarpAdapter.sol";
import {TeleporterAdapter} from "../../contracts/bridges/TeleporterAdapter.sol";

/// @title DeployAvalanche — Deploy the privacy stack to Avalanche C-Chain / Subnets
/// @notice Deploys: EpochManager, PrivacyPool, AWM adapter, Teleporter adapter
/// @dev Usage: forge script scripts/deploy/DeployAvalanche.s.sol \
///             --rpc-url $AVALANCHE_FUJI_RPC_URL --broadcast --verify
contract DeployAvalanche is Script {
    // ── Avalanche Configuration ────────────────────────────────────────

    // C-Chain blockchain ID (Fuji testnet)
    bytes32 constant FUJI_C_CHAIN_ID =
        0x7fc93d85c6d62c5b2ac0b519c87010ea5294012d1e407030d6acd0021cac10d5;

    // Teleporter messenger on Fuji
    address constant FUJI_TELEPORTER =
        0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf;

    // Epoch duration: 1 hour
    uint256 constant EPOCH_DURATION = 3600;

    // Avalanche domain chain ID for nullifier separation
    uint256 constant DOMAIN_CHAIN_ID = 43113; // Fuji chain ID
    uint256 constant DOMAIN_APP_ID = 1; // Privacy pool app ID

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deploying to Avalanche...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy a placeholder verifier (replace with real UltraHonk/Halo2 verifier)
        address verifier = _deployPlaceholderVerifier();
        console.log("Verifier deployed:", verifier);

        // 2. Deploy EpochManager
        EpochManager epochManager = new EpochManager(
            EPOCH_DURATION,
            DOMAIN_CHAIN_ID
        );
        console.log("EpochManager deployed:", address(epochManager));

        // 3. Deploy PrivacyPool
        PrivacyPool pool = new PrivacyPool(
            verifier,
            address(epochManager),
            DOMAIN_CHAIN_ID,
            DOMAIN_APP_ID,
            msg.sender,
            address(0)
        );
        console.log("PrivacyPool deployed:", address(pool));

        // 4. Authorize the pool in EpochManager
        epochManager.authorizePool(address(pool));

        // 5. Deploy AWM Bridge Adapter
        AvaxWarpAdapter warpAdapter = new AvaxWarpAdapter(FUJI_C_CHAIN_ID);
        console.log("AvaxWarpAdapter deployed:", address(warpAdapter));

        // 6. Deploy Teleporter Bridge Adapter
        TeleporterAdapter teleporterAdapter = new TeleporterAdapter(
            FUJI_TELEPORTER,
            FUJI_C_CHAIN_ID
        );
        console.log("TeleporterAdapter deployed:", address(teleporterAdapter));

        // 7. Authorize bridge adapters in EpochManager
        epochManager.authorizeBridge(address(warpAdapter));
        epochManager.authorizeBridge(address(teleporterAdapter));

        vm.stopBroadcast();

        // Log deployment summary
        console.log("\n=== Avalanche Deployment Summary ===");
        console.log("Verifier:          ", verifier);
        console.log("EpochManager:      ", address(epochManager));
        console.log("PrivacyPool:       ", address(pool));
        console.log("AvaxWarpAdapter:   ", address(warpAdapter));
        console.log("TeleporterAdapter: ", address(teleporterAdapter));
        console.log("Domain Chain ID:   ", DOMAIN_CHAIN_ID);
        console.log("Domain App ID:     ", DOMAIN_APP_ID);
    }

    /// @dev Placeholder verifier — returns true for all proofs.
    ///      MUST be replaced with real ZK verifier before any non-test deployment.
    function _deployPlaceholderVerifier() internal returns (address) {
        // Deploy a minimal contract that always returns true
        // This is ONLY for testnet scaffolding
        bytes memory bytecode = abi.encodePacked(
            hex"608060405234801561001057600080fd5b50610150806100206000396000f3fe",
            hex"608060405234801561001057600080fd5b506004361061004c5760003560e01c80",
            hex"63313ce567146100515780636b8d024f14610070578063a85e59e41461008f5780",
            hex"63f90ce5ba146100ae575b600080fd5b61005e6100cd565b60405190815260200160",
            hex"405180910390f35b61007d6100cd565b60405190815260200160405180910390f35b",
            hex"61009d6100cd565b60405190815260200160405180910390f35b6100bb6100cd565b",
            hex"60405190815260200160405180910390f35b600190565b"
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        return deployed;
    }
}
