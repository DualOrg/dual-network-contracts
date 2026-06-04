// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Ledger} from "../src/Ledger.sol";

/// @notice Deploys ONLY a new Ledger implementation contract (no proxy).
///
/// Use this when the upgrade authority executes `upgradeToAndCall(newImpl, "")`
/// on the proxy out-of-band, such as through a multisig/Safe.
///
/// Optional env vars:
///   DEPLOYER_ADDRESS     – account that broadcasts txs (defaults to msg.sender)
///   LEDGER_PROXY_ADDRESS – existing Ledger proxy; if set, the script logs current
///                          state for pre/post-upgrade comparison
///
/// Usage (dry-run):
///   forge script script/DeployLedgerImpl.s.sol --rpc-url <RPC> -vvvv
///
/// Usage (broadcast + verify):
///   forge script script/DeployLedgerImpl.s.sol --rpc-url <RPC> --broadcast --verify -vvvv
contract DeployLedgerImpl is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envOr("LEDGER_PROXY_ADDRESS", address(0));

        console2.log("=== DeployLedgerImpl ===");
        console2.log("Deployer      :", deployer);
        console2.log("Proxy (ref)   :", proxy);

        // If a proxy is provided, snapshot key state so it can be compared after
        // the upgrade is executed (storage must be untouched by a same-layout impl).
        if (proxy != address(0)) {
            Ledger ledger = Ledger(payable(proxy));
            console2.log("feeDispatcher        :", address(ledger.feeDispatcher()));
            console2.log("treasury             :", ledger.treasury());
            console2.log("feeDispatcherBps     :", ledger.feeDispatcherBps());
            console2.log("totalDeposited       :", ledger.totalDeposited());
            console2.log("totalFees            :", ledger.totalFees());
            console2.log("dispatchedFees       :", ledger.dispatchedFees());
            console2.log("treasuryFees         :", ledger.treasuryFees());
            console2.log("paused               :", ledger.paused());
        }

        vm.startBroadcast(deployer);

        // Deploy the implementation. The constructor calls _disableInitializers(),
        // so the implementation itself can never be initialized directly.
        Ledger implementation = new Ledger();
        console2.log("New implementation   :", address(implementation));

        vm.stopBroadcast();

        console2.log("=== Done ===");
        console2.log("Next: owner calls upgradeToAndCall(newImpl, \"\") on the proxy.");
    }
}
