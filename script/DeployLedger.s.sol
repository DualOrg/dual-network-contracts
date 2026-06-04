// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Ledger} from "../src/Ledger.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys Ledger (implementation + UUPS proxy).
///
/// Required env vars:
///   LEDGER_SENDER_ADDRESS  – address granted SENDER_ROLE for fee processing
///   TREASURY_ADDRESS       – treasury that receives the non-dispatcher fee share
///
/// Optional env vars:
///   OWNER_ADDRESS          – owner (defaults to DEPLOYER_ADDRESS)
///   FEE_DISPATCHER_ADDRESS – FeeDispatcher proxy (optional, zero = set later)
///   DEPLOYER_ADDRESS       – account that broadcasts txs (defaults to msg.sender)
///
/// Usage (dry-run):
///   forge script script/DeployLedger.s.sol --rpc-url <RPC> -vvvv
///
/// Usage (broadcast):
///   forge script script/DeployLedger.s.sol --rpc-url <RPC> --broadcast --verify -vvvv
contract DeployLedger is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address sender = vm.envAddress("LEDGER_SENDER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address feeDispatcher = vm.envOr("FEE_DISPATCHER_ADDRESS", address(0));

        if (feeDispatcher != address(0)) {
            require(
                FeeDispatcher(payable(feeDispatcher)).owner() == deployer,
                "DeployLedger: deployer must own FEE_DISPATCHER_ADDRESS"
            );
        }

        console2.log("=== DeployLedger ===");
        console2.log("Deployer      :", deployer);
        console2.log("Owner         :", owner);
        console2.log("Sender        :", sender);
        console2.log("Treasury      :", treasury);
        console2.log("FeeDispatcher :", feeDispatcher);

        vm.startBroadcast(deployer);

        // 1. Deploy implementation (constructor calls _disableInitializers).
        Ledger implementation = new Ledger();
        console2.log("Implementation:", address(implementation));

        // 2. Deploy UUPS proxy with initialize call.
        bytes memory initData =
            abi.encodeWithSelector(Ledger.initialize.selector, owner, feeDispatcher, sender, treasury);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console2.log("Proxy         :", address(proxy));

        // 3. Wire Ledger into FeeDispatcher if provided.
        if (feeDispatcher != address(0)) {
            FeeDispatcher(payable(feeDispatcher)).setLedger(address(proxy));
            console2.log("FeeDispatcher.setLedger done");
        } else {
            console2.log("WARNING: no FeeDispatcher - call FeeDispatcher.setLedger(proxy) manually");
        }

        vm.stopBroadcast();

        console2.log("=== Deploy complete ===");
    }
}
