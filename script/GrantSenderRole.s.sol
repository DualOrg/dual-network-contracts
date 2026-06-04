// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Ledger} from "../src/Ledger.sol";

contract GrantSenderRole is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address ledgerProxy = vm.envAddress("LEDGER_ADDRESS");
        address grantee = vm.envAddress("GRANTEE_ADDRESS");

        Ledger ledger = Ledger(ledgerProxy);
        require(ledger.owner() == deployer, "GrantSenderRole: deployer must own LEDGER_ADDRESS");

        console2.log("Deployer:       ", deployer);
        console2.log("Ledger:         ", ledgerProxy);
        console2.log("Granting SENDER_ROLE to:", grantee);

        vm.startBroadcast(deployer);
        ledger.grantSenderRole(grantee);
        vm.stopBroadcast();

        console2.log("Done. hasRole:", ledger.hasRole(ledger.SENDER_ROLE(), grantee));
    }
}
