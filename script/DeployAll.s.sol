// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {BatchRegistry} from "../src/BatchRegistry.sol";
import {BridgedNFTs} from "../src/BridgedNFTs.sol";
import {Ledger} from "../src/Ledger.sol";
import {Vault} from "../src/Vault.sol";
import {Staking} from "../src/StakingFinal.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";

/// @title DeployAll
/// @notice Deploys and configures the entire DUAL Network contract suite.
/// @dev Deployment order:
///      1. Vault (holds deposited DUAL and float)
///      2. FeeDispatcher (pulls from Vault, distributes to recipients)
///      3. Staking (receives fees via FeeDispatcher)
///      4. BatchRegistry (dispatches batch fees to FeeDispatcher)
///      5. Ledger (dispatches action fees to FeeDispatcher)
///      6. BridgedNFTs
///      7. Configure relationships and permissions
contract DeployAll is Script {
    struct DeployedContracts {
        address vault;
        address staking;
        address feeDispatcher;
        address batchRegistry;
        address ledger;
        address bridgedNFTs;
    }

    function run() external returns (DeployedContracts memory deployed) {
        // Read environment variables
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        address sequencer = vm.envOr("SEQUENCER_ADDRESS", owner);
        address sequencerNFT = vm.envOr("SEQUENCER_NFT_ADDRESS", owner);
        address ledgerSender = vm.envOr("LEDGER_SENDER_ADDRESS", owner);
        address zkVerifier = vm.envAddress("ZK_VERIFIER_ADDRESS");
        bytes32 fraudProofVKey = vm.envBytes32("FRAUD_PROOF_VKEY");
        bytes32 checkpointVKey = vm.envBytes32("CHECKPOINT_VKEY");
        uint256 challengeWindow = vm.envOr("CHALLENGE_WINDOW", uint256(5 minutes));
        uint256 challengeBond = vm.envOr(
            "CHALLENGE_BOND",
            uint256(100_000 ether) // MIN_CHALLENGE_BOND
        );
        uint256 rewardsDuration = vm.envOr("REWARDS_DURATION", uint256(7 days));
        string memory nftBaseUri = vm.envString("NFT_BASE_URI");

        // Fee distribution shares (basis points, 10000 = 100%).
        uint256 stakingBps = vm.envUint("STAKING_BPS");
        uint256 treasuryBps = vm.envUint("TREASURY_BPS");
        address treasury = vm.envOr("TREASURY_ADDRESS", owner);

        require(owner == deployer, "DeployAll: OWNER_ADDRESS must equal DEPLOYER_ADDRESS");
        require(stakingBps > 0 && stakingBps <= 10_000, "DeployAll: invalid STAKING_BPS");
        require(treasuryBps <= 10_000, "DeployAll: invalid TREASURY_BPS");
        require(stakingBps + treasuryBps <= 10_000, "DeployAll: BPS sum exceeds 10000");

        console2.log("=== Deployment Configuration ===");
        console2.log("Deployer:", deployer);
        console2.log("Owner:", owner);
        console2.log("Sequencer:", sequencer);
        console2.log("Ledger Sender:", ledgerSender);
        console2.log("ZK Verifier:", zkVerifier);
        console2.log("Challenge Window:", challengeWindow);
        console2.log("Challenge Bond:", challengeBond);
        console2.log("Treasury:", treasury);
        console2.log("Staking BPS:", stakingBps);
        console2.log("Treasury BPS:", treasuryBps);

        vm.startBroadcast(deployer);

        // ═══════════════════════════════════════════════════════════════════
        // 1. Deploy Vault
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying Vault ===");
        Vault vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeCall(Vault.initialize, (owner));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        deployed.vault = address(vaultProxy);
        console2.log("Vault:", deployed.vault);

        // ═══════════════════════════════════════════════════════════════════
        // 2. Deploy FeeDispatcher
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying FeeDispatcher ===");
        FeeDispatcher feeDispatcherImpl = new FeeDispatcher();
        bytes memory feeDispatcherInitData = abi.encodeCall(
            FeeDispatcher.initialize,
            (
                owner,
                deployed.vault,
                address(0), // batchRegistry - set after deployment
                address(0) // ledger - set after deployment
            )
        );
        ERC1967Proxy feeDispatcherProxy = new ERC1967Proxy(address(feeDispatcherImpl), feeDispatcherInitData);
        deployed.feeDispatcher = address(feeDispatcherProxy);
        console2.log("FeeDispatcher:", deployed.feeDispatcher);

        // ═══════════════════════════════════════════════════════════════════
        // 3. Deploy Staking
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying Staking ===");
        Staking stakingImpl = new Staking();
        bytes memory stakingInitData =
            abi.encodeCall(Staking.initialize, (owner, deployed.feeDispatcher, rewardsDuration));
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInitData);
        deployed.staking = address(stakingProxy);
        console2.log("Staking:", deployed.staking);

        // ═══════════════════════════════════════════════════════════════════
        // 4. Deploy BatchRegistry
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying BatchRegistry ===");
        BatchRegistry batchRegistryImpl = new BatchRegistry();
        bytes memory batchRegistryInitData = abi.encodeCall(
            BatchRegistry.initialize,
            (owner, sequencer, zkVerifier, fraudProofVKey, checkpointVKey, challengeWindow, challengeBond)
        );
        ERC1967Proxy batchRegistryProxy = new ERC1967Proxy(address(batchRegistryImpl), batchRegistryInitData);
        deployed.batchRegistry = address(batchRegistryProxy);
        console2.log("BatchRegistry:", deployed.batchRegistry);

        // ═══════════════════════════════════════════════════════════════════
        // 5. Deploy Ledger
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying Ledger ===");
        Ledger ledgerImpl = new Ledger();
        bytes memory ledgerInitData =
            abi.encodeCall(Ledger.initialize, (owner, deployed.feeDispatcher, ledgerSender, treasury));
        ERC1967Proxy ledgerProxy = new ERC1967Proxy(address(ledgerImpl), ledgerInitData);
        deployed.ledger = address(ledgerProxy);
        console2.log("Ledger:", deployed.ledger);

        // ═══════════════════════════════════════════════════════════════════
        // 6. Deploy BridgedNFTs
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deploying BridgedNFTs ===");
        BridgedNFTs nftImpl = new BridgedNFTs();
        bytes memory nftInitData =
            abi.encodeCall(BridgedNFTs.initialize, ("Dual Network NFT", "DNFT", sequencerNFT, owner, nftBaseUri));
        ERC1967Proxy nftProxy = new ERC1967Proxy(address(nftImpl), nftInitData);
        deployed.bridgedNFTs = address(nftProxy);
        console2.log("BridgedNFTs:", deployed.bridgedNFTs);

        // ═══════════════════════════════════════════════════════════════════
        // 7. Configure Relationships & Permissions
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Configuring Relationships ===");

        // 7a. Authorize FeeDispatcher on Vault
        console2.log("Setting FeeDispatcher on Vault...");
        Vault(payable(deployed.vault)).setFeeDispatcher(deployed.feeDispatcher);

        // 7b. Set BatchRegistry and Ledger in FeeDispatcher
        console2.log("Setting BatchRegistry and Ledger in FeeDispatcher...");
        FeeDispatcher(payable(deployed.feeDispatcher)).setBatchRegistry(deployed.batchRegistry);
        FeeDispatcher(payable(deployed.feeDispatcher)).setLedger(deployed.ledger);

        // 7c. Set FeeDispatcher in BatchRegistry
        console2.log("Setting FeeDispatcher in BatchRegistry...");
        BatchRegistry(payable(deployed.batchRegistry)).setFeeDispatcher(deployed.feeDispatcher);

        // 7d. Configure fee recipients in FeeDispatcher
        console2.log("Adding fee recipients...");

        // Add Staking contract
        FeeDispatcher(payable(deployed.feeDispatcher)).addRecipient(payable(deployed.staking), stakingBps);
        console2.log("  - Staking BPS:", stakingBps);
        console2.log("    Address:", deployed.staking);

        if (treasuryBps > 0) {
            FeeDispatcher(payable(deployed.feeDispatcher)).addRecipient(payable(treasury), treasuryBps);
            console2.log("  - Treasury BPS:", treasuryBps);
            console2.log("    Address:", treasury);
        }

        vm.stopBroadcast();

        // ═══════════════════════════════════════════════════════════════════
        // Final Summary
        // ═══════════════════════════════════════════════════════════════════
        console2.log("\n=== Deployment Complete ===");
        console2.log("Vault:", deployed.vault);
        console2.log("Staking:", deployed.staking);
        console2.log("FeeDispatcher:", deployed.feeDispatcher);
        console2.log("BatchRegistry:", deployed.batchRegistry);
        console2.log("Ledger:", deployed.ledger);
        console2.log("BridgedNFTs:", deployed.bridgedNFTs);
        console2.log("\n=== Configuration Summary ===");
        console2.log("FeeDispatcher can withdraw from:", deployed.vault);
        console2.log("BatchRegistry dispatches to:", deployed.feeDispatcher);
        console2.log("Ledger dispatches to:", deployed.feeDispatcher);
        console2.log("Fee Recipients:");
        console2.log("  - Staking");
        console2.log("    Address:", deployed.staking);
        console2.log("    BPS:", stakingBps);
        if (treasuryBps > 0) {
            console2.log("  - Treasury");
            console2.log("    Address:", treasury);
            console2.log("    BPS:", treasuryBps);
        }

        return deployed;
    }
}
