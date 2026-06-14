# `Staking` vs `StakingUpgrade`

This document records the **exact** differences between the canonical
[`Staking.sol`](../src/Staking.sol) contract and the upgrade implementation
[`StakingUpgrade.sol`](../src/StakingUpgrade.sol), and why those differences
exist.

## TL;DR

`StakingUpgrade` runs the **identical** staking/reward logic as `Staking`. It
exists only because `Staking.sol` is written as a *fresh deployment* and its
storage layout is **not** compatible with the already-deployed proxy.
`StakingUpgrade` is the same logic re-arranged to be storage-compatible with the
live proxy, plus a one-time `reinitializer` that wires up the missing
`ERC20Permit` domain and seeds one new field.

Every reward/streaming/claim function body is byte-for-byte identical. The only
code differences are listed exhaustively below.

## On-chain references (chain id `6301`, DUAL network)

| What | Address | Link |
|------|---------|------|
| Staking **proxy** (ERC-1967) | `0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1` | https://blockscout.dual.network/address/0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1 |
| **v1 implementation** (current `Staking` impl behind the proxy) | `0x49a81fefcf3d4f6e52a503744384472e4e141c82` | https://blockscout.dual.network/address/0x49a81fefcf3d4f6e52a503744384472e4e141c82 |
| FeeDispatcher (configured in v1) | `0xB66A65db8b78b19b5A8827830fc649Fb3425dFE5` | https://blockscout.dual.network/address/0xB66A65db8b78b19b5A8827830fc649Fb3425dFE5 |

RPC used for verification: `https://rpc.dual.network`.

> The "v1" deployed contract uses the field names `totalStaked`,
> `totalFeesDispatched`, `totalRewardsClaimed` and does **not** inherit
> `ERC20Permit` (its `committedRewards()` getter reverts). `StakingUpgrade` is
> the v2 implementation intended to replace impl `0x49a8…1c82` behind the same
> proxy.
>
> The v1 implementation source is **verified on Blockscout**. A copy is vendored
> at [`src/legacy/StakingV1.sol`](../src/legacy/StakingV1.sol) (contract renamed
> `Staking → StakingV1` to avoid a name clash) and used as the reference for the
> upgrade tests and the declared-layout diff below.

## Why `Staking.sol` cannot be deployed onto the proxy directly

The two contracts have the same *set* of sequential storage slots, but
`Staking.sol` places **`committedRewards` at slot 3**, whereas the live proxy
stores **staker principal (`totalStaked`) at slot 3**. Dropping `Staking.sol`
onto the proxy would reinterpret the principal balance as outstanding rewards —
catastrophic. `StakingUpgrade` fixes this by keeping `totalStaked` at slot 3 and
appending `committedRewards` into the reserved gap.

## Exact differences

The authoritative, comment-stripped diff is reproduced here. There are
**five** differences and nothing else.

### 1. Contract name

```solidity
- contract Staking is …
+ contract StakingUpgrade is …
```

### 2. Storage layout (slot order)

| Slot | `Staking.sol` | `StakingUpgrade.sol` | v1 deployed name |
|-----:|---------------|----------------------|------------------|
| 0 | `rewardPerTokenStored` | `rewardPerTokenStored` | `rewardPerTokenStored` |
| 1 | `userRewardPerTokenPaid` | `userRewardPerTokenPaid` | `userRewardPerTokenPaid` |
| 2 | `userAccruedRewards` | `userAccruedRewards` | `userAccruedRewards` |
| 3 | `committedRewards` | **`totalStaked`** | `totalStaked` |
| 4 | `lifetimeRewardsReceived` | `lifetimeRewardsReceived` | `totalFeesDispatched` |
| 5 | `lifetimeRewardsClaimed` | `lifetimeRewardsClaimed` | `totalRewardsClaimed` |
| 6 | `feeDispatcher` | `feeDispatcher` | `feeDispatcher` |
| 7 | `rewardRate` | `rewardRate` | `rewardRate` |
| 8 | `lastUpdateTime` | `lastUpdateTime` | `lastUpdateTime` |
| 9 | `periodFinish` | `periodFinish` | `periodFinish` |
| 10 | `rewardsDuration` | `rewardsDuration` | `rewardsDuration` |
| 11 | `pendingRewards` | `pendingRewards` | `pendingRewards` |
| 12 | `__gap[43]` | **`committedRewards`** | *(unused gap)* |
| 13 | — | `__gap[42]` | *(unused gap)* |

Notes:
- **Slots 0–11 of `StakingUpgrade` are byte-identical to the deployed proxy.**
  Slots 4 and 5 are pure renames of v1's `totalFeesDispatched` /
  `totalRewardsClaimed`; the stored values are preserved untouched.
- `StakingUpgrade` keeps `totalStaked` at slot 3 (the core logic never reads it;
  it equals `totalSupply()`), and appends `committedRewards` at slot 12 (was
  reserved gap → reads `0` on the live proxy until seeded).
- The `__gap` shrinks from `[43]` to `[42]` because the new
  `committedRewards` consumes one reserved slot. Total reserved storage is
  unchanged.
- All ERC20 / ERC20Permit / ERC20Votes / Ownable / Pausable state uses
  OpenZeppelin v5 ERC-7201 *namespaced* storage and therefore occupies **none**
  of these sequential slots — adding `ERC20Permit` to the inheritance list does
  not shift any slot above.

### 3. New function: `reinitializePermit()` (run once, at upgrade)

```solidity
function reinitializePermit() external onlyOwner reinitializer(2) {
    __ERC20Permit_init("Staked DUAL");
    committedRewards = lifetimeRewardsReceived - lifetimeRewardsClaimed; // uses v1 NET value
    lifetimeRewardsReceived += pendingRewards;                           // re-base net → gross
}
```

This does three things, atomically with the upgrade:
1. **Initialises the `ERC20Permit` (EIP-712) domain** that v1 never set (v1 did
   not inherit `ERC20Permit`).
2. **Seeds the new `committedRewards` field** = "live outstanding rewards" =
   `dispatched − claimed`. This is exact: v1's `totalFeesDispatched` (net) always
   equals `committedRewards + totalRewardsClaimed`, so
   `committedRewards = totalFeesDispatched − totalRewardsClaimed`. Safe because
   `claimed ≤ dispatched` (no underflow). Must be computed **before** step 3.
3. **Re-bases `lifetimeRewardsReceived` from net to gross** by adding the
   currently-parked `pendingRewards`. v1 kept slot 4 net of parked rewards, so it
   excludes the park (the ~9.85M on the live proxy). Without this the counter would
   under-state once parked rewards are claimed; with it, the invariant
   `received − claimed == committed + parked` holds from migration onward.

It mutates slot 4 only by the one-time net→gross re-base above; slot 5
(`lifetimeRewardsClaimed`) keeps its v1 value verbatim.

### 4. `stake()` — one extra line

```solidity
  _updateReward(msg.sender);
  uint256 rewardsToNotify = pendingRewards;
+ totalStaked += msg.value;
  _mint(msg.sender, msg.value);
```

### 5. `_unstakePrincipal()` — one extra line

```solidity
  function _unstakePrincipal(address user, uint256 amount) internal {
+     totalStaked -= amount;
      _burn(user, amount);
      _parkRemainingRewardsIfEmpty();
  }
```

> Differences 4 and 5 are the only changes inside the *normal operating* code
> paths, and they only maintain the `totalStaked` mirror (a redundant copy of
> `totalSupply()`). They have no effect on any reward, claim, or streaming
> calculation — the reward math reads `totalSupply()`, exactly like `Staking`.

## Field semantics (v1 → v2 mapping)

| v1 field (deployed) | v2 field | Relationship |
|---------------------|----------|--------------|
| `totalStaked` | `totalStaked` | Identical. Mirrors `totalSupply()`. |
| `totalFeesDispatched` | `lifetimeRewardsReceived` | Slot reused, value preserved. Re-purposed to a **cumulative external-inflow counter**: incremented once at ingestion (`receive()` / `addBonus()`) by the full amount received, never reduced, never double-counting parked-then-rescheduled rewards. v1 maintained this slot as a *net* figure (decremented on shrink/park); v2 counts gross inflow instead. Analytics only, never read by logic. |
| `totalRewardsClaimed` | `lifetimeRewardsClaimed` | **Rename only**, identical semantics, value preserved. |
| *(did not exist)* | `committedRewards` | **New** field: live outstanding rewards, and the **only** accounting field read by logic (`_availableForRewards`). Seeded once at migration from `lifetimeRewardsReceived − lifetimeRewardsClaimed` (the v1 *net* value), then maintained directly. After any park that expression no longer equals `committedRewards` (it equals committed + parked), so do not use it as live outstanding. |

`lifetimeRewardsReceived` and `lifetimeRewardsClaimed` are write-only analytics
counters (never read by logic). `committedRewards` is the single accounting
field that drives a decision (the reward-solvency guard in `_notifyReward`).

## Storage-compatibility verification (performed on-chain)

The deployed proxy's layout was confirmed empirically (without trusting source
text) by matching each public getter against its raw storage slot via
`eth_getStorageAt` + `eth_call`:

| Slot | Getter | Value | Match |
|-----:|--------|-------|:-----:|
| 6 | `feeDispatcher()` | `0xB66A65…dFE5` | ✓ exact |
| 10 | `rewardsDuration()` | `604800` (7 days) | ✓ exact |
| 11 | `pendingRewards()` | `~3.27e24` | ✓ |
| 12 | `committedRewards()` | **reverts** | ✓ slot is unused gap in v1 |

At the time of writing the proxy is in a near-pristine state: no stakers
(`totalSupply == 0`, `totalStaked == 0`), no active stream
(`rewardRate == periodFinish == lastUpdateTime == 0`), and zero reward
accounting (`totalFeesDispatched == totalRewardsClaimed == 0`). The only
non-zero state is `feeDispatcher`, `rewardsDuration` (7 days) and
`pendingRewards` (~3.27M DUAL parked while nobody is staked yet). Consequently
the `reinitializePermit` seed evaluates to `committedRewards = 0 − 0 = 0` — a
no-op — and `pendingRewards` at slot 11 is preserved unchanged.

### Declared-layout diff (against the real verified v1 source)

Beyond the on-chain probe, the new layout was diffed against the **actual
verified v1 source** ([`src/legacy/StakingV1.sol`](../src/legacy/StakingV1.sol))
via `forge inspect … storageLayout`:

| Slot | v1 (deployed) | `StakingUpgrade` | Verdict |
|-----:|---------------|------------------|---------|
| 0–11 | identical types & positions | identical types & positions | ✅ unchanged (slots 4,5 are name-only) |
| 12 | `uint256[43] __gap` | `uint256 committedRewards` | ✅ new var appended into reserved gap |
| 13 | — | `uint256[42] __gap` | ✅ gap shrinks 43→42; total reserved storage unchanged |

This is the same property OpenZeppelin's upgrade validator enforces: existing
slots keep their type and position, and new state is appended into the reserved
gap.

## Tests & tooling

| File | Purpose |
|------|---------|
| [`src/legacy/StakingV1.sol`](../src/legacy/StakingV1.sol) | Verified deployed v1 source (renamed), used as the upgrade reference |
| [`test/StakingUpgrade.t.sol`](../test/StakingUpgrade.t.sol) | Local upgrade simulation with **non-zero** reward state + optional live-fork test |
| [`script/UpgradeStaking.s.sol`](../script/UpgradeStaking.s.sol) | Performs `upgradeToAndCall(impl, reinitializePermit)` and asserts the seed/permit |

The local simulation (`forge test --mp test/StakingUpgrade.t.sol`) deliberately
builds non-zero `totalFeesDispatched`/`totalRewardsClaimed` (stake → notify →
claim) so the cumulative→outstanding migration is actually exercised — the live
chain is currently all zeros. It asserts every preserved field, that each
staker's `previewRewards` is unchanged across the upgrade, that claims still work
and the contract stays solvent, that the permit domain equals the intended
`("Staked DUAL","1")` domain and a real permit signature verifies, and that
`reinitializePermit` is `onlyOwner` + runs exactly once.

The fork test runs against the live proxy:

```
DUAL_FORK_RPC=https://rpc.dual.network forge test --mt test_Fork
```

## Upgrade procedure

The upgrade and the reinitializer must be executed **atomically** so the proxy
is never live with an uninitialised permit domain / unseeded `committedRewards`:

```solidity
// owner-only; _authorizeUpgrade is onlyOwner
proxy.upgradeToAndCall(
    address(newStakingUpgradeImpl),
    abi.encodeCall(StakingUpgrade.reinitializePermit, ())
);
```

`reinitializer(2)` ensures `reinitializePermit` can run exactly once and can
never re-run on a future upgrade. In practice, run it via the script (owner key):

```
STAKING_PROXY_ADDRESS=0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1 \
forge script script/UpgradeStaking.s.sol --rpc-url https://rpc.dual.network --broadcast -vvvv
```
