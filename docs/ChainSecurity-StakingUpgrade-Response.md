# Response to Preliminary Report

**Project:** Staking Upgrade (`StakingFinal.sol`)
**Auditor:** ChainSecurity
**Reviewed commit:** `977525ee359d060aadbaed1fbdf8d81f18398fa0`
**Response date:** 2026-06-14

This document responds to the preliminary report. It records our feedback on the
findings, the modifications made, and the items we do not intend to change.

---

## Assessment overview review

**ACCEPTED.** The Assessment Overview accurately reflects the system, scope, and
the upgrade procedure (direct `StakingV1` → `StakingFinal` upgrade executed
atomically with `reinitializePermit()`).

Two naming corrections made on our side (no behavioural impact on the in-scope
logic): (1) a stale NatSpec comment named the appended slot as the v1 counter; the
appended slot is `committedRewards` (slot 12). (2) As part of the #003 fix the
slot-4 getter `lifetimeRewardsScheduled()` was renamed to `lifetimeRewardsReceived()`
to match its corrected semantics (see #003). The report's §3.9.2 view-function
table should reflect the new getter name.

---

## System Considerations review

**ACCEPTED.**

- **SC1 — First Staker Captures Full Parked Reward Stream After the Upgrade.**
  Accurate. Addressed by **process**, not code; no contract change required.

  The ~9.85M DUAL in `pendingRewards` streams **linearly over the 7-day
  `rewardsDuration`** once the first stake folds it into a stream. A staker that is
  alone therefore captures only `rewardRate × (time alone)`, i.e. a fraction
  `(time alone) / 7 days` of the pool — independent of stake size. The exposure is
  bounded by the **alone-window**, not by capital:

  | Alone for | % of pool captured |
  |-----------|--------------------|
  | 10 minutes | ~0.10% |
  | 1 hour | ~0.60% |
  | 1 day | ~14% |

  The mitigation is to keep the alone-window to minutes. We will publish a public
  countdown to a **synchronized opening time** and `unpause()` at that moment, so a
  broad set of users stake within the first block(s). Stakers landing in the same
  block share the stream strictly pro-rata by capital (reward accrual is
  time-based, so zero time elapses between same-block stakes and no first-mover
  advantage accrues within a block). As insurance against low turnout, the
  treasury may additionally seed a stake in the same transaction as `unpause()`,
  which caps any external first-mover's capture regardless of transaction ordering.
  At a 7-day duration, a realistic few-minute window bounds the leak to well under
  ~0.1% of the pool, consistent with the report's low-severity classification.

- **SC2 — Stakers Must Be Able to Receive Native DUAL.**
  Accurate and intended. Payout via `call` with revert-on-failure is by design
  (rejecting a failed transfer is preferred to silently stranding funds). xDUAL is
  freely transferable, so a contract that cannot receive native DUAL can move its
  shares to one that can. Documented for integrators.

---

## New system state

Final commit including all modifications below:

- **`492bdda7c2583bd4b158e5e32bc772e78a69c753`**

History: #005 (the `stake()` re-scheduling fix) landed in
`4e7cf3b`; the #003 inflow-counter fix and rename in `cb60b95`; the #003
migration-seed re-base in `492bdda`. The commit above is the tip and includes all
of the above. Full `forge test` suite passes (382 passed, 1 skipped — the
RPC-gated live-fork test).

---

## Findings

### #001 Reward Duration Cannot Be Updated While a Stream Is Active

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [x] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
  The core behaviour — `setRewardsDuration` being unavailable while a stream is
  active — is intended: we do not want the streaming period reshaped under
  stakers' feet mid-distribution. Under genuine, continuous fee flow the owner
  changes the duration by pausing (which parks inflows and blocks new stakes) and
  waiting out the active period, exactly as the report describes. We accept this
  operational constraint.

  The report additionally notes the lock could be sustained **permissionlessly**,
  because any `stake()` that folds parked rewards also re-armed the period. That
  permissionless vector has been **removed in code** (see #005, commit
  `4e7cf3b`): a `stake()` now folds parked rewards only when no period is active
  (`block.timestamp >= periodFinish`), so a staker can no longer re-arm or sustain
  the lock. The residual, owner-facing constraint under real fee traffic remains
  by design.
- **Commit hash (if applicable)**: `4e7cf3b` (permissionless re-arm removed)

---

### #002 A Small Reward Notification Closes an Active Reward Period

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [x] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
  Confirmed and accepted. The early-closure branch is only reachable for
  dust-scale pools whose entire scheduled reward is below `rewardsDuration²` in wei
  (~3.66e-7 DUAL for a 7-day duration), so it has no practical economic effect.
  No funds are at risk: `_updateReward(address(0))` credits rewards streamed up to
  the closing block, and `committedRewards` / `pendingRewards` are conserved, with
  `committedRewards >= leftover` always holding so the decrement cannot underflow.
  The terminated remainder is deferred to the next notification. We accept the
  observable effect (an active period ending without a `RewardsNotified` event).
- **Commit hash (if applicable)**: —

---

### #003 lifetimeRewardsScheduled over-States Outstanding Rewards After a Shrink or Empty-Pool Park

- **Status**:
  - [x] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
  Fixed, and the slot-4 field/getter was **renamed** `lifetimeRewardsScheduled` →
  `lifetimeRewardsReceived` to match its corrected semantics.

  Root cause: the counter was incremented inside the streaming path
  (`_replaceLeftoverRewards`, by `scheduled - leftover` on each notify), so rewards
  that were parked and later re-scheduled were counted again — the counter could
  exceed total fees ever received, and after the first park
  `(scheduled) - (claimed)` over-stated live outstanding.

  The increment was moved to the single external-inflow choke point,
  `_ingestRewards`, where it now counts the full received `amount` **exactly once**
  at receipt (covering both `receive()` fees and `addBonus()`), regardless of any
  later park or re-schedule. `lifetimeRewardsReceived` is therefore a faithful
  cumulative inflow total. No reward, claim, or solvency logic was touched —
  `committedRewards` remains the sole field read by `_availableForRewards`, and its
  updates are byte-for-byte unchanged. NatSpec on both contracts now states that
  `committedRewards` is authoritative and that `lifetimeRewardsReceived -
  lifetimeRewardsClaimed` equals committed + parked, not live outstanding.

  Migration seed: `committedRewards` is still seeded from the v1 *net* value
  (`dispatched - claimed`, 0 on the live proxy) and is unchanged. The migration
  additionally **re-bases** `lifetimeRewardsReceived` from v1's net figure to gross
  by adding the parked `pendingRewards` (on the live proxy, the ~9.85M park), so the
  counter starts at the true total ever received. Without this re-base the counter
  would *under*-state by the pre-migration parked balance once it is claimed (and
  `claimed` would exceed `received`); the invariant suite caught exactly this.

  Applied to both `StakingFinal` (in scope) and the canonical `Staking`. Tests:
  `test_LifetimeRewardsReceived_CountsInflowsOnce` (counter equals total external
  DUAL sent across a park-then-reschedule cycle, never more) in each suite, plus
  `_CountsFeesAndBonusOnce` and `_CountsParkedInflowAtReceipt` unit tests, and a new
  `invariant_rewardInflowConserved` fuzz invariant on **both** the canonical and the
  migration suites asserting
  `lifetimeRewardsReceived - lifetimeRewardsClaimed == committedRewards + pendingRewards`.

  Note for the report: the §3.9.2 getter `lifetimeRewardsScheduled()` is now
  `lifetimeRewardsReceived()`.
- **Commit hash (if applicable)**: `cb60b95` (inflow-counter fix + rename) and `492bdda` (migration-seed net→gross re-base)

---

### #004 Migration Changes the EIP-712 Domain Used for Vote Delegation Signatures

- **Status**:
  - [ ] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [x] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
  Confirmed and accepted. Initializing the ERC20Permit / EIP-712 domain to
  (`Staked DUAL`, `1`) is the intended purpose of the migration; the shared domain
  change invalidates any `delegateBySig` signature produced against the v1 proxy
  and requires post-migration signatures to use the new domain. In practice this
  is a non-event for this deployment: the proxy currently has no stakers and no
  outstanding xDUAL, so there are no live delegation signatures to invalidate.
  Post-migration signing follows the standard (`Staked DUAL`, `1`) domain.
- **Commit hash (if applicable)**: —

---

### #005 Re-Scheduling a Reward Stream Can Lower the Effective Rate and Extend the Period

- **Status**:
  - [x] Code Change
  - [ ] Specification Change
  - [ ] Process Change
  - [ ] Risk Accepted
  - [ ] No Issue
  - [ ] Other:
- **Description of changes**:
  Fixed. `stake()` previously folded `pendingRewards` into `_notifyReward()`
  whenever `pendingRewards > 0`, which — because each notification re-amortises the
  un-streamed leftover over a fresh full `rewardsDuration` — let any account
  permissionlessly lower the effective rate and push `periodFinish` out, for free,
  by repeatedly triggering it (even with 1-wei or dust stakes).

  The fold is now gated on there being **no active stream**:

  ```solidity
  if (pendingRewards > 0 && block.timestamp >= periodFinish) {
      uint256 rewardsToNotify = pendingRewards;
      pendingRewards = 0;
      _notifyReward(rewardsToNotify);
  }
  ```

  A `stake()` can therefore only *bootstrap* a stream when none is active; it can
  no longer re-notify a live stream. Parked dust accrued during an active period is
  folded by the next legitimate fee inflow (`receive()` / `addBonus()`) or once the
  current period ends. The bootstrap path (first stake into an idle/parked pool,
  e.g. immediately after the upgrade) is unchanged.

  Applied to both `StakingFinal` (in scope) and the canonical `Staking`. Regression
  tests added in each suite (`test_Stake_DoesNotRescheduleActiveStream`) asserting
  that a mid-stream stake leaves `rewardRate`, `periodFinish`, and parked
  `pendingRewards` untouched, and that repeated dust stakes cannot push the finish
  out. Organic rescheduling on genuine fee inflows is intentionally retained.
- **Commit hash (if applicable)**: `4e7cf3b`
