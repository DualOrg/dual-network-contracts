// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";

/// @notice Upgrades an existing BatchRegistry UUPS proxy to the latest implementation.
///
/// Required env vars:
///   BATCH_REGISTRY_PROXY_ADDRESS – address of the deployed BatchRegistry proxy
///
/// Optional env vars:
///   DEPLOYER_ADDRESS       – account that broadcasts txs (defaults to msg.sender)
///
/// Usage (dry-run):
///   forge script script/UpgradeBatchRegistry.s.sol --rpc-url <RPC> -vvvv
///
/// Usage (broadcast):
///   forge script script/UpgradeBatchRegistry.s.sol --rpc-url <RPC> --broadcast --verify -vvvv
contract UpgradeBatchRegistry is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envAddress("BATCH_REGISTRY_PROXY_ADDRESS");

        console2.log("=== BatchRegistry Upgrade ===");
        console2.log("Deployer :", deployer);
        console2.log("Proxy    :", proxy);

        // Sanity-check: the proxy must already look like a BatchRegistry.
        BatchRegistry registry = BatchRegistry(payable(proxy));
        address currentOwner = registry.owner();
        console2.log("Current owner from proxy:", currentOwner);
        require(currentOwner == deployer, "UpgradeBatchRegistry: deployer is not proxy owner");

        // Log key state so we can verify nothing shifts after the upgrade.
        console2.log("batchCount                  :", registry.batchCount());
        console2.log("highestFinalizedBatchNumber :", registry.highestFinalizedBatchNumber());
        console2.log("lastBatchHash               :");
        console2.logBytes32(registry.lastBatchHash());
        console2.log("lastIntegrityRoot            :");
        console2.logBytes32(registry.lastIntegrityRoot());
        console2.log("paused                      :", registry.paused());

        vm.startBroadcast(deployer);

        // 1. Deploy the new implementation (constructor calls _disableInitializers).
        BatchRegistry newImpl = new BatchRegistry();
        console2.log("New implementation          :", address(newImpl));

        // 2. Upgrade the proxy — no re-initialization needed; all state is preserved.
        //    upgradeToAndCall with empty data is equivalent to plain upgradeTo.
        registry.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console2.log("=== Upgrade complete ===");
    }
}
