// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";

/// @notice Upgrades an existing FeeDispatcher UUPS proxy to the latest implementation.
///
/// Required env vars:
///   FEE_DISPATCHER_PROXY_ADDRESS – address of the deployed FeeDispatcher proxy
///
/// Optional env vars:
///   DEPLOYER_ADDRESS             – account that broadcasts txs (defaults to msg.sender)
///
/// Usage (dry-run):
///   forge script script/UpgradeFeeDispatcher.s.sol --rpc-url <RPC> -vvvv
///
/// Usage (broadcast):
///   forge script script/UpgradeFeeDispatcher.s.sol --rpc-url <RPC> --broadcast --verify -vvvv
contract UpgradeFeeDispatcher is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envAddress("FEE_DISPATCHER_PROXY_ADDRESS");

        console2.log("=== FeeDispatcher Upgrade ===");
        console2.log("Deployer      :", deployer);
        console2.log("Proxy         :", proxy);

        // Sanity-check: proxy must already look like a FeeDispatcher.
        FeeDispatcher dispatcher = FeeDispatcher(payable(proxy));
        address currentOwner = dispatcher.owner();
        console2.log("Current owner from proxy:", currentOwner);
        require(currentOwner == deployer, "UpgradeFeeDispatcher: deployer is not proxy owner");

        // Log key state so we can verify nothing shifts after the upgrade.
        console2.log("vault                 :", dispatcher.vault());
        console2.log("batchRegistry         :", dispatcher.batchRegistry());
        console2.log("ledger                :", dispatcher.ledger());
        console2.log("totalFeesDispatched   :", dispatcher.totalFeesDispatched());
        console2.log("totalFeesDistributed  :", dispatcher.totalFeesDistributed());
        console2.log("totalFeesRetained     :", dispatcher.totalFeesRetained());
        console2.log("recipientCount        :", dispatcher.getRecipientCount());
        console2.log("paused                :", dispatcher.paused());

        vm.startBroadcast(deployer);

        // 1. Deploy the new implementation (constructor calls _disableInitializers).
        FeeDispatcher newImpl = new FeeDispatcher();
        console2.log("New implementation    :", address(newImpl));

        // 2. Upgrade the proxy — no re-initialization needed; all state is preserved.
        dispatcher.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console2.log("=== Upgrade complete ===");
    }
}
