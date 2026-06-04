// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBridgedNFTs is Script {
    function run() external {
        // 1. Setup Environment Variables
        // Identities default to the deployer; NFT_BASE_URI must be explicit.
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address sequencer = vm.envOr("SEQUENCER_NFT_ADDRESS", owner);
        string memory baseUri = vm.envString("NFT_BASE_URI");

        console2.log("--- Deployment Info ---");
        console2.log("Deployer:", deployer);
        console2.log("Sequencer:", sequencer);
        console2.log("Owner:", owner);
        console2.log("Base URI:", baseUri);

        vm.startBroadcast(deployer);

        // 2. Deploy Logic Implementation
        BridgedNFTs implementation = new BridgedNFTs();
        console2.log("Implementation Address:", address(implementation));

        // 3. Encode the Initializer Call
        // This includes the sequencer, owner, and baseUri
        bytes memory initData = abi.encodeWithSelector(
            BridgedNFTs.initialize.selector, "Dual Network NFT", "DNFT", sequencer, owner, baseUri
        );

        // 4. Deploy Proxy
        // Points to the implementation and calls the full initializer.
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        console2.log("Proxy Address (Your NFT Contract):", address(proxy));

        vm.stopBroadcast();
        console2.log("------------------------");
    }
}
