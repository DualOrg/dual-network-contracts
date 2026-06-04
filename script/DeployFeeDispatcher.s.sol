// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployFeeDispatcher is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address vault = vm.envOr("VAULT_ADDRESS", address(0));
        address batchRegistry = vm.envOr("BATCH_REGISTRY_ADDRESS", address(0));
        address ledger = vm.envOr("LEDGER_ADDRESS", address(0));

        if (vault != address(0)) {
            require(Vault(payable(vault)).owner() == deployer, "DeployFeeDispatcher: deployer must own VAULT_ADDRESS");
        }

        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Vault:", vault);
        console2.log("Batch Registry:", batchRegistry);
        console2.log("Ledger:", ledger);

        vm.startBroadcast(deployer);

        // 1. Deploy implementation
        FeeDispatcher implementation = new FeeDispatcher();
        console2.log("Implementation deployed at:", address(implementation));

        // 2. Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(FeeDispatcher.initialize.selector, owner, vault, batchRegistry, ledger);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        console2.log("FeeDispatcher Proxy deployed at:", address(proxy));

        // 3. Authorize FeeDispatcher on Vault
        if (vault != address(0)) {
            console2.log("Setting FeeDispatcher on Vault...");
            Vault(payable(vault)).setFeeDispatcher(address(proxy));
            console2.log("Permission granted successfully");
        } else {
            console2.log("WARNING: No vault provided. Call Vault.setFeeDispatcher(proxy) manually.");
        }

        vm.stopBroadcast();
    }
}
