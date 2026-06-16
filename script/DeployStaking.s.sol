// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Staking} from "../src/StakingFinal.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployStaking is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address feeDispatcher = vm.envAddress("FEE_DISPATCHER_ADDRESS");
        uint256 rewardsDuration = vm.envOr("REWARDS_DURATION", uint256(7 days));

        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Fee Dispatcher:", feeDispatcher);
        console2.log("Rewards Duration:", rewardsDuration);

        vm.startBroadcast(deployer);

        // 1. Deploy implementation
        Staking implementation = new Staking();
        console2.log("Implementation deployed at:", address(implementation));

        // 2. Deploy proxy
        bytes memory initData =
            abi.encodeWithSelector(Staking.initialize.selector, owner, feeDispatcher, rewardsDuration);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        console2.log("Staking Proxy deployed at:", address(proxy));

        console2.log("FeeDispatcher set during initialization");

        vm.stopBroadcast();
    }
}
