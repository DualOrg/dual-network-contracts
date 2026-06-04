# Staking: v1 → v2 changes

What changes when the live Staking proxy is upgraded from the deployed **v1**
implementation to **v2** (`StakingUpgrade`). This is the real-world,
behaviour-and-ABI delta seen by users and integrators — not the internal
source-vs-source comparison (for that, see
[`staking-upgrade.md`](./staking-upgrade.md)).

## Identities

| | Contract | Source | Address |
|--|----------|--------|---------|
| **Proxy** (unchanged) | ERC-1967 / UUPS | — | [`0x69AD…Dcc1`](https://blockscout.dual.network/address/0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1) |
| **v1 impl** (current) | `Staking` | [`src/legacy/StakingV1.sol`](../src/legacy/StakingV1.sol) (verified copy of the deployed source) | [`0x49a8…1c82`](https://blockscout.dual.network/address/0x49a81fefcf3d4f6e52a503744384472e4e141c82) |
| **v2 impl** (new) | `StakingUpgrade` | [`src/StakingUpgrade.sol`](../src/StakingUpgrade.sol) | *(deployed at upgrade)* |

The proxy address and all staker balances/principal/rewards are **preserved**.
The upgrade is performed with
`upgradeToAndCall(v2impl, reinitializePermit())` (owner-only, atomic).

## Summary of changes

| # | Change | Type | Impact |
|---|--------|------|--------|
| 1 | **ERC20Permit added** | Feature | Gasless approvals (EIP-2612) for xDUAL |
| 2 | **`emergencyWithdraw` / `withdrawableSurplus` removed** | Governance | Owner can no longer pull surplus DUAL |
| 3 | **Self-delegation broadened** | Behaviour | Any xDUAL receiver auto-delegates, not just stakers |
| 4 | **Reward accounting fields renamed + `committedRewards` added** | ABI / storage | Getter names change; behaviour identical |
| 5 | **`_notifyReward` refactored into helpers** | Internal | No behaviour change |
| 6 | **`reinitializePermit()` migration added** | Upgrade-only | Runs once during the upgrade |
| 7 | **Fees received while paused are parked, not streamed** | Behaviour | Distribution of new inflows is deferred to `unpause()` |

Reward math, staking/unstaking, fee streaming, `exit`, `addBonus`, and governance
(`ERC20Votes`, timestamp clock) are otherwise **unchanged**.

## 7. Fees parked while paused (behaviour change)

In v1, fees/bonuses arriving while the contract was paused were immediately streamed.
In v2 they are **parked** into `pendingRewards` and scheduled when the owner calls
`unpause()` (or on the next `stake()`), so no *new* reward distribution starts during a
pause. An already-active stream still runs to completion. `pause()` continues to block
only `stake()`; `unstake` / `claimRewards` / `exit` remain open.

---

## 1. ERC20Permit added (new feature)

v1 did not inherit `ERC20PermitUpgradeable`. v2 does, enabling **EIP-2612 gasless
approvals** of the xDUAL token.

- New external surface: `permit(...)`, `DOMAIN_SEPARATOR()`, `nonces(address)`,
  `eip712Domain()`.
- Because the proxy was deployed without a permit domain, v2 initialises it
  post-upgrade in `reinitializePermit()` (see §6). The domain is
  `name="Staked DUAL"`, `version="1"`.

## 2. `emergencyWithdraw` / `withdrawableSurplus` removed (governance change)

> **This is the most consequential behavioural change.**

v1 exposed:

```solidity
function withdrawableSurplus() public view returns (uint256);
function emergencyWithdraw(address to, uint256 amount) external onlyOwner;
event  EmergencyWithdraw(address indexed to, uint256 amount);
error  ExceedsWithdrawableSurplus();
```

These let the owner withdraw any DUAL **above** principal + committed +
pending rewards. **v2 removes all of them.** After the upgrade the owner can no
longer extract surplus DUAL by any path — funds can only leave via staker
`unstake` / `claimRewards` / `exit`. This is a deliberate reduction of owner
privilege (matching the canonical `Staking` design).

Any off-chain tooling calling `emergencyWithdraw()` or `withdrawableSurplus()`
will revert after the upgrade.

## 3. Self-delegation broadened (minor behaviour change)

`ERC20Votes` requires an account to delegate before its balance counts as voting
power.

- **v1** self-delegated only **stakers**, inside `stake()`:
  ```solidity
  if (delegates(msg.sender) == address(0)) _delegate(msg.sender, msg.sender);
  ```
- **v2** self-delegates **any** xDUAL receiver, inside `_update()`:
  ```solidity
  if (to != address(0) && delegates(to) == address(0)) _delegate(to, to);
  ```

Effect: an address that receives xDUAL via **transfer** (not just by staking)
now automatically gains voting power. Existing stakers are unaffected (they were
already self-delegated under v1).

## 4. Reward-accounting fields: renamed + one added

Behaviour is identical; the storage **values** are preserved and only the
**names / getters** change. (Live-outstanding rewards were a *derived* quantity
in v1 and become a *stored* field in v2.)

| v1 field (slot) | v2 field (slot) | Note |
|-----------------|-----------------|------|
| `totalStaked` (3) | `totalStaked` (3) | unchanged |
| `totalFeesDispatched` (4) | `lifetimeRewardsScheduled` (4) | rename, value preserved |
| `totalRewardsClaimed` (5) | `lifetimeRewardsClaimed` (5) | rename, value preserved |
| — | `committedRewards` (12, new) | live outstanding = `scheduled − claimed`, seeded at upgrade |

In v1, available-for-rewards used `totalFeesDispatched − totalRewardsClaimed`. In
v2 the same quantity is maintained directly as `committedRewards`. The reward
solvency guard and all payouts behave identically.

## 5. `_notifyReward` refactored into helpers (no behaviour change)

v2 decomposes the v1 inline streaming logic into named internal helpers:
`_leftoverRewards`, `_rewardSchedule`, `_replaceLeftoverRewards`, `_parkRewards`,
`_closeRewardPeriod`, `_startRewardPeriod`, plus `_unstakePrincipal` and
`_claimAccrued`. Pure readability refactor; outputs are identical.

## 6. `reinitializePermit()` — one-time upgrade migration

```solidity
function reinitializePermit() external onlyOwner reinitializer(2) {
    __ERC20Permit_init("Staked DUAL");
    committedRewards = lifetimeRewardsScheduled - lifetimeRewardsClaimed;
}
```

Runs **once**, atomically with the upgrade. It (a) initialises the ERC20Permit
domain v1 never had, and (b) seeds the new `committedRewards` from the preserved
v1 counters (`= totalFeesDispatched − totalRewardsClaimed`; safe because
`claimed ≤ dispatched`). It mutates no existing slot.

---

## ABI change cheat-sheet (for integrators)

**Removed selectors** (calls revert after upgrade):
- `emergencyWithdraw(address,uint256)`
- `withdrawableSurplus()`
- `totalFeesDispatched()` → renamed to `lifetimeRewardsScheduled()`
- `totalRewardsClaimed()` → renamed to `lifetimeRewardsClaimed()`
- event `EmergencyWithdraw`, error `ExceedsWithdrawableSurplus`

**Added selectors:**
- `committedRewards()`, `lifetimeRewardsScheduled()`, `lifetimeRewardsClaimed()`
- `reinitializePermit()`
- ERC20Permit: `permit(...)`, `DOMAIN_SEPARATOR()`, `nonces(address)`, `eip712Domain()`

**Unchanged:** `stake`, `unstake`, `claimRewards`, `exit`, `previewRewards`,
`addBonus`, `setFeeDispatcher`, `setRewardsDuration`, `pause`/`unpause`,
`feeDispatcher`, `rewardRate`, `periodFinish`, `rewardsDuration`,
`pendingRewards`, `totalStaked`, `rewardPerToken`, all ERC20 / ERC20Votes
methods, and all events for staking/rewards.

## Verification

- **State preserved across the upgrade** — proven by
  [`test/StakingUpgrade.t.sol`](../test/StakingUpgrade.t.sol): a local simulation
  builds non-zero reward state on a real v1 proxy, upgrades to v2, and asserts
  every preserved field, each staker's unchanged `previewRewards`, working claims
  / solvency, and a functioning permit domain.
- **Live fork** — the same suite upgrades the **actual** on-chain proxy in a fork
  (`DUAL_FORK_RPC=https://rpc.dual.network forge test --mt test_Fork`) and passes.
- **Storage layout** — slots 0–11 are byte-identical to v1; `committedRewards`
  is appended into the reserved gap (`__gap[43]→[42]`). See
  [`staking-upgrade.md`](./staking-upgrade.md) for the full layout diff.
