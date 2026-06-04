// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";

/// @notice Upgrades an existing BridgedNFTs UUPS proxy to the latest implementation.
///
/// Required env vars:
///   BRIDGED_NFTS_PROXY_ADDRESS – address of the deployed BridgedNFTs proxy
///
/// Optional env vars:
///   DEPLOYER_ADDRESS           – account that broadcasts txs (defaults to msg.sender)
///
/// Usage (dry-run):
///   forge script script/UpgradeBridgedNFTs.s.sol --rpc-url <RPC> -vvvv
///
/// Usage (broadcast):
///   forge script script/UpgradeBridgedNFTs.s.sol --rpc-url <RPC> --broadcast --verify -vvvv
contract UpgradeBridgedNFTs is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envAddress("BRIDGED_NFTS_PROXY_ADDRESS");

        console2.log("=== BridgedNFTs Upgrade ===");
        console2.log("Deployer :", deployer);
        console2.log("Proxy    :", proxy);

        BridgedNFTs nfts = BridgedNFTs(proxy);
        address currentOwner = nfts.owner();
        console2.log("Current owner from proxy:", currentOwner);
        require(currentOwner == deployer, "UpgradeBridgedNFTs: deployer is not proxy owner");

        console2.log("name (before)   :", nfts.name());
        console2.log("symbol (before) :", nfts.symbol());
        console2.log("sequencer       :", nfts.sequencer());
        console2.log("totalSupply     :", nfts.totalSupply());
        console2.log("paused          :", nfts.paused());

        vm.startBroadcast(deployer);

        BridgedNFTs newImpl = new BridgedNFTs();
        console2.log("New implementation :", address(newImpl));

        nfts.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console2.log("name (after)    :", nfts.name());
        console2.log("symbol (after)  :", nfts.symbol());
        console2.log("=== Upgrade complete ===");
    }
}
