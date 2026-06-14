// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StakingFinal} from "../src/StakingFinal.sol";

/// @dev Minimal view interface for the deployed v1 implementation, whose getters
///      use the pre-rename field names (`totalFeesDispatched`/`totalRewardsClaimed`)
///      and which has no `committedRewards()`. Used only to log pre-upgrade state.
interface IStakingV1Readout {
    function owner() external view returns (address);
    function feeDispatcher() external view returns (address);
    function rewardsDuration() external view returns (uint256);
    function pendingRewards() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function totalFeesDispatched() external view returns (uint256);
    function totalRewardsClaimed() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Upgrades the live Staking UUPS proxy from the v1 implementation to
///         `StakingFinal`, running `reinitializePermit()` atomically so the
///         proxy is never live with an uninitialised ERC20Permit domain or an
///         unseeded `committedRewards`.
///
/// Required env vars:
///   STAKING_PROXY_ADDRESS – address of the deployed Staking proxy
///
/// Optional env vars:
///   DEPLOYER_ADDRESS      – account that broadcasts txs (defaults to msg.sender);
///                           MUST be the proxy owner (_authorizeUpgrade is onlyOwner).
///
/// Usage (dry-run):
///   STAKING_PROXY_ADDRESS=0x69AD... \
///   forge script script/UpgradeStaking.s.sol --rpc-url https://rpc.dual.network -vvvv
///
/// Usage (broadcast):
///   STAKING_PROXY_ADDRESS=0x69AD... \
///   forge script script/UpgradeStaking.s.sol --rpc-url https://rpc.dual.network --broadcast --verify -vvvv
contract UpgradeStaking is Script {
    function run() external {
        address deployer = vm.envOr("DEPLOYER_ADDRESS", msg.sender);
        address proxy = vm.envAddress("STAKING_PROXY_ADDRESS");

        IStakingV1Readout v1 = IStakingV1Readout(proxy);
        address currentOwner = v1.owner();

        console2.log("=== Staking Upgrade (v1 -> StakingFinal) ===");
        console2.log("Deployer            :", deployer);
        console2.log("Proxy               :", proxy);
        console2.log("Current owner       :", currentOwner);
        require(currentOwner == deployer, "UpgradeStaking: deployer is not proxy owner");

        // Snapshot v1 state so it can be eyeballed against post-upgrade values.
        uint256 dispatched = v1.totalFeesDispatched();
        uint256 claimed = v1.totalRewardsClaimed();
        console2.log("feeDispatcher       :", v1.feeDispatcher());
        console2.log("rewardsDuration     :", v1.rewardsDuration());
        console2.log("pendingRewards      :", v1.pendingRewards());
        console2.log("totalStaked         :", v1.totalStaked());
        console2.log("totalSupply         :", v1.totalSupply());
        console2.log("totalFeesDispatched :", dispatched);
        console2.log("totalRewardsClaimed :", claimed);
        console2.log("=> committedRewards seed (dispatched - claimed):", dispatched - claimed);

        vm.startBroadcast(deployer);

        // 1. Deploy the new implementation (constructor calls _disableInitializers).
        StakingFinal newImpl = new StakingFinal();
        console2.log("New implementation  :", address(newImpl));

        // 2. Upgrade + initialise ERC20Permit + seed committedRewards, atomically.
        StakingFinal(payable(proxy)).upgradeToAndCall(
            address(newImpl), abi.encodeCall(StakingFinal.reinitializePermit, ())
        );

        vm.stopBroadcast();

        // Post-upgrade readback.
        StakingFinal s = StakingFinal(payable(proxy));
        console2.log("--- post-upgrade ---");
        console2.log("committedRewards         :", s.committedRewards());
        console2.log("lifetimeRewardsReceived :", s.lifetimeRewardsReceived());
        console2.log("lifetimeRewardsClaimed   :", s.lifetimeRewardsClaimed());
        console2.log("pendingRewards           :", s.pendingRewards());
        console2.log("DOMAIN_SEPARATOR set     :", s.DOMAIN_SEPARATOR() != bytes32(0));
        require(s.committedRewards() == dispatched - claimed, "UpgradeStaking: committedRewards seed mismatch");
        require(s.DOMAIN_SEPARATOR() != bytes32(0), "UpgradeStaking: permit domain not initialised");

        console2.log("=== Upgrade complete ===");
    }
}
