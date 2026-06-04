// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Vault} from "../src/Vault.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Staking} from "../src/Staking.sol";
import {Ledger} from "../src/Ledger.sol";

/// @title DeployCore
/// @notice Deploys and configures Vault, FeeDispatcher, Staking, and Ledger.
contract DeployCore is Script {
    struct DeployedCore {
        address vault;
        address feeDispatcher;
        address staking;
        address ledger;
    }

    function run() external returns (DeployedCore memory deployed) {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address ledgerSender = vm.envOr("LEDGER_SENDER_ADDRESS", owner);

        uint256 rewardsDuration = vm.envOr("REWARDS_DURATION", uint256(7 days));
        uint256 stakingBps = vm.envUint("STAKING_BPS");
        uint256 treasuryBps = vm.envUint("TREASURY_BPS");
        address treasury = vm.envOr("TREASURY_ADDRESS", owner);

        require(owner == deployer, "DeployCore: OWNER_ADDRESS must equal DEPLOYER_ADDRESS");
        require(stakingBps > 0 && stakingBps <= 10_000, "invalid STAKING_BPS");
        require(treasuryBps <= 10_000, "invalid TREASURY_BPS");
        require(stakingBps + treasuryBps <= 10_000, "bps sum > 10000");

        console2.log("=== Core Deployment Configuration ===");
        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Treasury:", treasury);
        console2.log("Rewards Duration:", rewardsDuration);
        console2.log("Staking BPS:", stakingBps);
        console2.log("Treasury BPS:", treasuryBps);

        vm.startBroadcast(deployer);

        // 1) Vault
        Vault vaultImpl = new Vault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), abi.encodeCall(Vault.initialize, (owner)));
        deployed.vault = address(vaultProxy);
        console2.log("Vault:", deployed.vault);

        // 2) FeeDispatcher (vault set immediately, ledger set after ledger deploy)
        FeeDispatcher feeDispatcherImpl = new FeeDispatcher();
        ERC1967Proxy feeDispatcherProxy = new ERC1967Proxy(
            address(feeDispatcherImpl),
            abi.encodeCall(
                FeeDispatcher.initialize,
                (
                    owner,
                    deployed.vault,
                    address(0), // batchRegistry (unused in this core deploy)
                    address(0) // ledger (set after Ledger deployment)
                )
            )
        );
        deployed.feeDispatcher = address(feeDispatcherProxy);
        console2.log("FeeDispatcher:", deployed.feeDispatcher);

        // 3) Staking (requires non-zero feeDispatcher at initialize)
        Staking stakingImpl = new Staking();
        ERC1967Proxy stakingProxy = new ERC1967Proxy(
            address(stakingImpl), abi.encodeCall(Staking.initialize, (owner, deployed.feeDispatcher, rewardsDuration))
        );
        deployed.staking = address(stakingProxy);
        console2.log("Staking:", deployed.staking);

        // 4) Ledger
        Ledger ledgerImpl = new Ledger();
        ERC1967Proxy ledgerProxy = new ERC1967Proxy(
            address(ledgerImpl),
            abi.encodeCall(Ledger.initialize, (owner, deployed.feeDispatcher, ledgerSender, treasury))
        );
        deployed.ledger = address(ledgerProxy);
        console2.log("Ledger:", deployed.ledger);

        // 5) Wire relationships and permissions
        Vault(payable(deployed.vault)).setFeeDispatcher(deployed.feeDispatcher);
        FeeDispatcher(payable(deployed.feeDispatcher)).setLedger(deployed.ledger);

        FeeDispatcher(payable(deployed.feeDispatcher)).addRecipient(payable(deployed.staking), stakingBps);

        if (treasuryBps > 0) {
            FeeDispatcher(payable(deployed.feeDispatcher)).addRecipient(payable(treasury), treasuryBps);
        }

        vm.stopBroadcast();

        console2.log("\n=== Core Deployment Complete ===");
        console2.log("Vault:", deployed.vault);
        console2.log("FeeDispatcher:", deployed.feeDispatcher);
        console2.log("Staking:", deployed.staking);
        console2.log("Ledger:", deployed.ledger);

        return deployed;
    }
}
