// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PrivacyPool} from "../../contracts/core/PrivacyPool.sol";
import {EpochManager} from "../../contracts/core/EpochManager.sol";
import {IbcBridgeAdapter} from "../../contracts/bridges/IbcBridgeAdapter.sol";

/// @title DeployEvmos — Deploy the privacy stack to Evmos (Cosmos EVM)
/// @dev Usage: forge script scripts/deploy/DeployEvmos.s.sol \
///             --rpc-url $EVMOS_TESTNET_RPC_URL --broadcast
contract DeployEvmos is Script {
    uint256 constant EPOCH_DURATION = 3600;
    uint256 constant DOMAIN_APP_ID = 1;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Deploying to Evmos...");

        vm.startBroadcast(deployerKey);

        address verifier = _deployPlaceholderVerifier();
        EpochManager epochManager = new EpochManager(
            EPOCH_DURATION,
            block.chainid
        );
        PrivacyPool pool = new PrivacyPool(
            verifier,
            address(epochManager),
            block.chainid,
            DOMAIN_APP_ID,
            msg.sender,
            address(0)
        );
        epochManager.authorizePool(address(pool));

        IbcBridgeAdapter ibcAdapter = new IbcBridgeAdapter();
        epochManager.authorizeBridge(address(ibcAdapter));

        vm.stopBroadcast();

        console.log("\n=== Evmos Deployment Summary ===");
        console.log("Verifier:     ", verifier);
        console.log("EpochManager: ", address(epochManager));
        console.log("PrivacyPool:  ", address(pool));
        console.log("IbcAdapter:   ", address(ibcAdapter));
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
