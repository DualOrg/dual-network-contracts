# Staking v2 (`StakingUpgrade`) — Recommendations & Known Design Behavior

What to do before/around the upgrade, and the intentional design choices to be
aware of. Resolved code issues are not listed here — only open recommendations
and accepted behavior.

> Internal engineering review, not a formal third-party audit. Commission an
> external audit before relying on this for production assurances.

| | |
|--|--|
| **Contract** | [`src/StakingUpgrade.sol`](../src/StakingUpgrade.sol) (twin: [`src/Staking.sol`](../src/Staking.sol)) |
| **v1 reference** | [`src/legacy/StakingV1.sol`](../src/legacy/StakingV1.sol) (verified deployed source) |
| **Proxy (chain 6301)** | [`0x69AD…Dcc1`](https://blockscout.dual.network/address/0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1) |
| **v1 impl** | [`0x49a8…1c82`](https://blockscout.dual.network/address/0x49a81fefcf3d4f6e52a503744384472e4e141c82) |
| **Owner** | `0x0AE84910170e7942aA87f58649865e097bdfdfa6` |

## Safety basis

No critical/high logic issues were found. Safety rests on one invariant, which is
fuzz-verified over 128k randomized calls on a migrated proxy
([`test/StakingUpgradeInvariant.t.sol`](../test/StakingUpgradeInvariant.t.sol)):

```
balance ≥ totalSupply()  +  committedRewards  +  pendingRewards
         (principal)        (owed rewards)       (parked)
```

Because per-user accrual rounds **down**, `committedRewards ≥ Σ userAccruedRewards`
always — the contract is over-, never under-collateralized, and the reward
counters cannot underflow.

---

## Recommendations (open action items)

### R-1 — Upgrade only via the atomic `reinitializePermit` path *(operational, do this)*
The implementation swap and the migration **must** execute in one transaction:
```
upgradeToAndCall(newImpl, abi.encodeCall(StakingUpgrade.reinitializePermit, ()))
```
A plain `upgradeTo` (empty calldata) leaves `committedRewards = 0` while the
lifetime counters hold real values → over-scheduling and `committedRewards -= amount`
underflow on claim (DoS). Use [`script/UpgradeStaking.s.sol`](../script/UpgradeStaking.s.sol),
which does this and asserts the seed + permit domain. Never expose a non-atomic
upgrade path.
*(Recoverable if missed — `reinitializer(2)` isn't consumed by a plain upgrade, so
the owner can still call `reinitializePermit()` afterward; and on today's all-zero
proxy the seed is `0` regardless. But treat the atomic path as mandatory.)*

### R-2 — Move ownership to a multisig / timelock *(highest residual risk)*
`_authorizeUpgrade` is `onlyOwner`, so the owner can replace the implementation
with arbitrary code and move all funds — this is the only remaining fund-extraction
path (direct `emergencyWithdraw` was removed in v2). The current owner looks like an
EOA. A multisig limits key risk; a timelock also gives stakers advance notice of
upgrades. Ownership transfer is 2-step (`Ownable2Step`), so the move is safe.

---

## Known design behavior (intentional / accepted)

### No emergency withdrawal
v2 removed `emergencyWithdraw` / `withdrawableSurplus`. The owner cannot extract
surplus DUAL by any direct path; funds leave only via staker `unstake` /
`claimRewards` / `exit`. Deliberate reduction of owner privilege.

### Pause behavior
`pause()` blocks `stake()` but **not** `unstake` / `claimRewards` / `exit` — holders
can always recover funds, even while paused. Fees/bonuses **received while paused are
parked** into `pendingRewards` (not streamed) and scheduled on `unpause()` (or the
next stake). Note: an *already-active* stream still runs to completion during the
pause — only the start of *new* distribution is deferred.

### Rounding dust is retained, not recoverable
Two remainders arise from integer math:
1. **Scheduling remainder** (`dust` in `_rewardSchedule`) is parked into
   `pendingRewards` and folded into the next notify — recycled, not lost.
2. **Per-user accrual remainder** (floor divisions `/supply` and `/PRECISION`) leaves
   a wei-scale residue in `committedRewards` permanently.

This is inherent to the Synthetix-style `rewardPerToken` accumulator and is benign —
it sits on the *safe* side of the solvency inequality (over-collateralization). With
`emergencyWithdraw` removed it is unrecoverable, but the amounts are economically
irrelevant. **Do not** raise `PRECISION` (erodes overflow headroom) or add a recovery
hatch (reintroduces an extraction surface). Note: arbitrary ERC-20s sent to the
contract are likewise stuck; force-sent native ETH simply becomes staker rewards.

### Contract stakers that reject ETH can brick their own withdrawals
`unstake` / `claimRewards` / `exit` push native DUAL via `.call` and revert on
failure. A contract whose `receive` reverts cannot withdraw — but xDUAL is
transferable, so it can move tokens to an EOA and withdraw there. Integrator caveat,
no code change.

### First staker captures the parked-reward stream
When `totalSupply == 0` with non-zero `pendingRewards` (today's proxy: ~3.27M DUAL
parked), the first `stake()` mints then notifies, so that staker earns the stream
until others join. Streaming prevents *instantaneous* capture (unstaking re-parks the
un-streamed remainder), so it's a fairness note, not theft.

### Transferable xDUAL + auto self-delegation
`_update` accrues rewards for both transfer parties and self-delegates any new holder,
so voting power follows token transfers. `ERC20Votes` caps supply at `2^208−1`
(unreachable). Intended; flagged for integrators.

---

## Upgrade & storage safety (reference)

- Slots 0–11 are byte-identical to deployed v1 (verified on-chain via getter↔
  `eth_getStorageAt`, and against the verified v1 source via `forge inspect`).
  `committedRewards` is appended at slot 12 (was reserved gap); `__gap[43]→[42]`.
- Adding `ERC20Permit` shifts no storage (OZ v5 namespaced storage; its `EIP712`/
  `Nonces` deps were already inherited via `ERC20Votes`).
- `reinitializePermit` re-inits **only** `ERC20Permit` — not `Ownable`/`Pausable`/
  `ReentrancyGuard` — so owner and guard state survive the upgrade.
- Full layout diff: [`staking-upgrade.md`](./staking-upgrade.md). Behaviour/ABI delta:
  [`staking-v1-to-v2.md`](./staking-v1-to-v2.md).

## Test coverage (reference)

| Suite | Covers |
|-------|--------|
| [`StakingUpgrade.t.sol`](../test/StakingUpgrade.t.sol) | local v1→v2 migration + **live fork**: state preserved, seed correct, `previewRewards` unchanged, claim/exit/solvency, permit, reinitializer guards |
| [`StakingUpgradeInvariant.t.sol`](../test/StakingUpgradeInvariant.t.sol) | 10 invariants × 128k calls on a migrated proxy (solvency, accrued-covered, conservation, votes, liveness) |
| [`StakingInvariant.t.sol`](../test/StakingInvariant.t.sol) | same invariants for a fresh `Staking.sol` deploy |
| [`Staking.t.sol`](../test/Staking.t.sol) + integration/symbolic | 59 unit tests + integration + symbolic notify |
