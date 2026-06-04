// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../src/Vault.sol";

contract DeployVault is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);

        vm.startBroadcast(deployer);

        // 1) Deploy implementation
        Vault impl = new Vault();

        // 2) Encode initializer
        bytes memory initData = abi.encodeCall(Vault.initialize, (owner));

        // 3) Deploy proxy pointing to implementation
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // 4) Cast proxy address to the contract ABI for convenience
        Vault vault = Vault(payable(address(proxy)));

        console2.log("Implementation:", address(impl));
        console2.log("Proxy:", address(vault));
        console2.log("Owner:", vault.owner());

        vm.stopBroadcast();
    }
}
