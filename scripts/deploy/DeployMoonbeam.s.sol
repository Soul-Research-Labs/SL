// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {XcmBridgeAdapter} from "../../contracts/bridges/XcmBridgeAdapter.sol";

/// @title DeployMoonbeam — Deploy the privacy stack to Moonbeam / Moonbase Alpha
/// @notice Deploys: EpochManager, PrivacyPool, XCM bridge adapter
/// @dev Usage: forge script scripts/deploy/DeployMoonbeam.s.sol \
///             --rpc-url $MOONBASE_ALPHA_RPC_URL --broadcast --verify
contract DeployMoonbeam is Script {
    // ── Moonbeam Configuration ─────────────────────────────────────────

    // Moonbase Alpha chain ID
    uint256 constant MOONBASE_CHAIN_ID = 1287;
    // Moonbeam mainnet parachain ID
    uint32 constant MOONBEAM_PARA_ID = 2004;
    // Moonbase Alpha parachain ID
    uint32 constant MOONBASE_PARA_ID = 1000;

    // Epoch duration: 1 hour
    uint256 constant EPOCH_DURATION = 3600;

    uint256 constant DOMAIN_APP_ID = 1;

    // Known parachain IDs for route registration
    uint32 constant ASTAR_PARA_ID = 2006;
    uint256 constant ASTAR_CHAIN_ID = 592;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        bool isTestnet = block.chainid == MOONBASE_CHAIN_ID;
        uint32 thisParaId = isTestnet ? MOONBASE_PARA_ID : MOONBEAM_PARA_ID;

        console.log("Deploying to Moonbeam...");
        console.log("Deployer:", deployer);
        console.log("Testnet:", isTestnet);
        console.log("ParaId:", thisParaId);

        vm.startBroadcast(deployerKey);

        // 1. Placeholder verifier
        address verifier = _deployPlaceholderVerifier();
        console.log("Verifier:", verifier);

        // 2. Deploy EpochManager
        EpochManager epochManager = new EpochManager(
            EPOCH_DURATION,
            block.chainid
        );
        console.log("EpochManager:", address(epochManager));

        // 3. Deploy PrivacyPool
        PrivacyPool pool = new PrivacyPool(
            verifier,
            address(epochManager),
            block.chainid,
            DOMAIN_APP_ID,
            msg.sender,
            address(0)
        );
        console.log("PrivacyPool:", address(pool));

        epochManager.authorizePool(address(pool));

        // 4. Deploy XCM Bridge Adapter
        XcmBridgeAdapter xcmAdapter = new XcmBridgeAdapter(thisParaId);
        console.log("XcmBridgeAdapter:", address(xcmAdapter));

        epochManager.authorizeBridge(address(xcmAdapter));

        vm.stopBroadcast();

        console.log("\n=== Moonbeam Deployment Summary ===");
        console.log("Verifier:       ", verifier);
        console.log("EpochManager:   ", address(epochManager));
        console.log("PrivacyPool:    ", address(pool));
        console.log("XcmAdapter:     ", address(xcmAdapter));
        console.log("ParaId:         ", thisParaId);
        console.log("Domain Chain ID:", block.chainid);
    }

    function _deployPlaceholderVerifier() internal returns (address) {
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
