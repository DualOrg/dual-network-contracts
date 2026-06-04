// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployBatchRegistry is Script {
    function run() external {
        // 1. Setup Environment Variables
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address sequencer = vm.envOr("SEQUENCER_ADDRESS", owner);
        address zkVerifier = vm.envAddress("ZK_VERIFIER_ADDRESS");
        bytes32 fraudProofVKey = vm.envBytes32("FRAUD_PROOF_VKEY");
        bytes32 checkpointVKey = vm.envBytes32("CHECKPOINT_VKEY");
        uint256 challengeWindow = vm.envOr("CHALLENGE_WINDOW", uint256(5 minutes));
        uint256 challengeBond = vm.envOr(
            "CHALLENGE_BOND",
            uint256(100_000 ether) // MIN_CHALLENGE_BOND
        );

        console2.log("Deployer:", deployer);
        console2.log("Sequencer:", sequencer);
        console2.log("Owner:", owner);
        console2.log("ZK Verifier:", zkVerifier);
        console2.log("Challenge Window:", challengeWindow);
        console2.log("Challenge Bond:", challengeBond);
        console2.logBytes32(fraudProofVKey);
        console2.logBytes32(checkpointVKey);

        vm.startBroadcast(deployer);

        // 2. Deploy Implementation Contract
        BatchRegistry implementation = new BatchRegistry();
        console2.log("Implementation deployed at:", address(implementation));

        // 3. Prepare Initialization Data
        bytes memory initData = abi.encodeWithSelector(
            BatchRegistry.initialize.selector,
            owner,
            sequencer,
            zkVerifier,
            fraudProofVKey,
            checkpointVKey,
            challengeWindow,
            challengeBond
        );

        // 4. Deploy Proxy Contract
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        console2.log("BatchRegistry Proxy deployed at:", address(proxy));

        vm.stopBroadcast();
    }
}
