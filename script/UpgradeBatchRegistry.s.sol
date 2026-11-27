// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BatchRegistry} from "../src/BatchRegistry.sol";

/// @notice Upgrades the BatchRegistry UUPS proxy to the finalizing-checkpoint implementation and
///         runs `reinitializeCheckpoints` atomically, so the proxy is never live without the
///         bond floor, the checkpoint bound and the batch-number index of the pending batches.
///
/// Required env vars:
///   BATCH_REGISTRY_PROXY_ADDRESS – address of the deployed BatchRegistry proxy
///   MIN_CHALLENGE_BOND           – challenge bond floor in wei
///   MAX_CHECKPOINT_BATCHES       – longest range one checkpoint may cover
///
/// Optional env vars:
///   PENDING_BATCH_HASHES         – comma-separated hashes of every batch after the last checkpoint,
///                                  batch numbers lastCheckpointBatchNumber + 1 to batchCount, in
///                                  order (unset when none); see docs/DEPLOYMENT.md
///   DEPLOYER_ADDRESS             – the proxy owner (defaults to msg.sender)
///
/// Run it only after the V4 cutover (`setCheckpointState(hash(N), batchNumber(N))`, spec 12.1
/// step 6): the verifier accepts that rewrite only before the start event this upgrade emits, and
/// `reinitializer(2)` cannot run again.
///
/// Simulate only (`make dry-run-upgrade-batch-registry`). The Make broadcast targets for this
/// upgrade refuse to run; the owner deploys the implementation and sends
/// `upgradeToAndCall(implementation, data)` with the logged data.
contract UpgradeBatchRegistry is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envAddress("BATCH_REGISTRY_PROXY_ADDRESS");
        bytes32[] memory pending = vm.envOr("PENDING_BATCH_HASHES", ",", new bytes32[](0));
        uint256 minChallengeBond = vm.envUint("MIN_CHALLENGE_BOND");
        uint256 maxCheckpointBatches = vm.envUint("MAX_CHECKPOINT_BATCHES");

        BatchRegistry registry = BatchRegistry(payable(proxy));
        require(registry.owner() == deployer, "UpgradeBatchRegistry: deployer is not proxy owner");

        console2.log("=== BatchRegistry Upgrade (finalizing checkpoints) ===");
        console2.log("WARNING: run only after the V4 cutover setCheckpointState (spec 12.1 step 6);");
        console2.log("         the start event is final and reinitializer(2) cannot run again.");
        console2.log("Proxy                       :", proxy);
        console2.log("Owner                       :", deployer);
        console2.log("batchCount                  :", registry.batchCount());
        console2.log("highestFinalizedBatchNumber :", registry.highestFinalizedBatchNumber());
        console2.log("lastCheckpointBatchNumber   :", registry.lastCheckpointBatchNumber());
        console2.log("lastCheckpointBatchHash     :");
        console2.logBytes32(registry.lastCheckpointBatchHash());
        console2.log("challengeBond               :", registry.challengeBond());
        console2.log("batch hashes to backfill    :", pending.length);
        console2.log("minChallengeBond            :", minChallengeBond);
        console2.log("maxCheckpointBatches        :", maxCheckpointBatches);

        bytes memory initData =
            abi.encodeCall(BatchRegistry.reinitializeCheckpoints, (pending, minChallengeBond, maxCheckpointBatches));

        vm.startBroadcast(deployer);
        BatchRegistry newImpl = new BatchRegistry();
        registry.upgradeToAndCall(address(newImpl), initData);
        vm.stopBroadcast();

        console2.log("New implementation          :", address(newImpl));
        console2.log("upgradeToAndCall data argument (reinitializeCheckpoints call):");
        console2.logBytes(initData);
        console2.log("=== Simulated upgrade complete ===");
    }
}
