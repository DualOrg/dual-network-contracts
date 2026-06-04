// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proof of the _notifyReward reward-reconciliation arithmetic.
/// @notice `reconcile` below is a FAITHFUL MIRROR of the committed-rewards
///         bookkeeping in Staking._notifyReward (the dust park + the
///         `scheduled >= leftover` reconciliation + the `scheduled == 0`
///         close). It deliberately omits the balance-dependent RewardRateTooHigh
///         guard and the timestamp plumbing, which are not part of the pure
///         arithmetic and are covered by the invariant suite against the real
///         contract.
///
///         The property proven here generalizes the M-1 fix to ALL inputs:
///         committed + parked rewards change by EXACTLY `amount`, with no
///         double-counting of the released shortfall and no underflow.
contract StakingNotifySymbolicTest is Test {
    /// @dev Mirrors Staking._notifyReward lines ~376-405. Returns the updated
    ///      (committedRewards, pendingRewards, rewardRate).
    function reconcile(
        uint256 amount,
        uint256 leftover,
        uint256 rewardsDuration,
        uint256 committed, // committedRewards (before)
        uint256 pending // pendingRewards (before)
    ) internal pure returns (uint256 newCommitted, uint256 newPending, uint256 newRate) {
        uint256 totalToSchedule = amount + leftover;
        newRate = totalToSchedule / rewardsDuration;
        uint256 scheduled = newRate * rewardsDuration;
        uint256 dust = totalToSchedule - scheduled;

        newPending = pending;
        if (dust > 0) {
            newPending += dust;
        }

        // (RewardRateTooHigh guard intentionally omitted — balance-dependent.)

        if (scheduled >= leftover) {
            committed += scheduled - leftover;
        } else {
            committed -= leftover - scheduled;
        }

        if (scheduled == 0) {
            newRate = 0;
        }
        newCommitted = committed;
    }

    /// @dev Common, realistic preconditions enforced by the live contract.
    function _assume(uint256 amount, uint256 leftover, uint256 rewardsDuration, uint256 committed) internal pure {
        // Duration is bounded by MIN/MAX_REWARDS_DURATION in the contract.
        vm.assume(rewardsDuration >= 1 hours && rewardsDuration <= 30 days);
        // `leftover` is the unstreamed remainder of the prior schedule and is
        // always covered by committed accounting: committed >= leftover.
        vm.assume(committed >= leftover);
        // No uint256 overflow on amount + leftover (true for any plausible token).
        vm.assume(amount <= type(uint256).max - leftover);
    }

    /// @notice CONSERVATION: committed + parked rewards rise by exactly `amount`.
    ///         This is the property M-1 violated (it rose by amount + shortfall).
    function check_conservation(
        uint256 amount,
        uint256 leftover,
        uint256 rewardsDuration,
        uint256 committed,
        uint256 pending
    ) public pure {
        _assume(amount, leftover, rewardsDuration, committed);
        // No overflow when measuring reserved totals.
        vm.assume(committed <= type(uint256).max - pending);

        uint256 reservedBefore = committed + pending;
        (uint256 newCommitted, uint256 newPending,) = reconcile(amount, leftover, rewardsDuration, committed, pending);
        uint256 reservedAfter = newCommitted + newPending;

        assert(reservedAfter - reservedBefore == amount);
    }

    /// @notice NO UNDERFLOW: the `tfd -= leftover - scheduled` branch never
    ///         underflows given the real precondition tfd >= leftover.
    function check_noUnderflow(
        uint256 amount,
        uint256 leftover,
        uint256 rewardsDuration,
        uint256 committed,
        uint256 pending
    ) public pure {
        _assume(amount, leftover, rewardsDuration, committed);
        vm.assume(committed <= type(uint256).max - pending);

        // If this reverts (underflow), halmos reports a counterexample.
        (uint256 newCommitted,,) = reconcile(amount, leftover, rewardsDuration, committed, pending);
        // Committed accounting never goes below what stays scheduled.
        assert(newCommitted <= committed + amount);
    }

    /// @notice DUST BOUND: parked rewards grow by strictly less than one
    ///         rewardsDuration (the rounding remainder), and never shrink.
    /// @dev Verified by FUZZING, not symbolic proof: discharging the modulo bound
    ///      `(x mod d) < d` symbolically times out in the SMT solver. Fuzzing
    ///      covers it instantly, and the property is elementary. (Named `testFuzz_`
    ///      so forge runs it and halmos skips it.)
    function testFuzz_DustBounded(uint256 amount, uint256 leftover, uint256 committed, uint256 pending, uint8 pick)
        public
        pure
    {
        uint256 rewardsDuration = pick % 3 == 0 ? 1 hours : (pick % 3 == 1 ? 7 days : 30 days);
        amount = bound(amount, 0, type(uint128).max);
        leftover = bound(leftover, 0, type(uint128).max);
        pending = bound(pending, 0, type(uint128).max);
        committed = bound(committed, leftover, type(uint128).max); // real precondition: committed >= leftover

        (, uint256 newPending,) = reconcile(amount, leftover, rewardsDuration, committed, pending);
        uint256 parked = newPending - pending;
        assert(newPending >= pending);
        assert(parked < rewardsDuration);
    }

    /// @notice RATE BACKED: the scheduled stream (newRate * duration) never
    ///         exceeds the funds in play (amount + leftover).
    function check_rateNeverExceedsFunds(
        uint256 amount,
        uint256 leftover,
        uint256 rewardsDuration,
        uint256 committed,
        uint256 pending
    ) public pure {
        _assume(amount, leftover, rewardsDuration, committed);
        vm.assume(amount < 2 ** 128 && leftover < 2 ** 128);

        (,, uint256 newRate) = reconcile(amount, leftover, rewardsDuration, committed, pending);
        assert(newRate * rewardsDuration <= amount + leftover);
    }
}
