// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proofs of the BatchRegistry bond / surplus arithmetic.
/// @notice Mirrors the three money-handling computations:
///         - withdrawableSurplus (lines 553-558)
///         - the bond move in resolveChallenge (lines 313-321)
///         - the pending-withdrawal debit in claimWithdrawal (lines 403-404)
contract BatchRegistrySymbolicTest is Test {
    /// @notice Surplus never underflows and never exceeds the balance.
    function check_surplusNeverUnderflows(uint256 balance, uint256 reserved) public pure {
        uint256 surplus = balance <= reserved ? 0 : balance - reserved; // mirror
        assert(surplus <= balance);
        // Surplus is exactly the unreserved balance, or zero when fully reserved.
        if (balance > reserved) {
            assert(surplus == balance - reserved);
        } else {
            assert(surplus == 0);
        }
    }

    /// @notice Resolving a challenge moves the bond from active to pending without
    ///         changing the total reserved (no value created or destroyed) and
    ///         without underflowing the active-bond total.
    function check_bondMoveConserves(uint256 activeBonds, uint256 pending, uint256 bond) public pure {
        // Precondition: the bond is part of the active total (always true on-chain).
        vm.assume(bond <= activeBonds);
        vm.assume(pending <= type(uint256).max - bond); // no overflow on credit

        uint256 newActive = activeBonds - bond; // line 313
        uint256 newPending = pending + bond; // line 317 / 321

        assert(newActive + newPending == activeBonds + pending); // reserved conserved
        assert(newActive <= activeBonds);
    }

    /// @notice Claiming debits the pending total by exactly the claimed amount
    ///         with no underflow (amount is the caller's own pending balance,
    ///         which is <= the total).
    function check_claimNoUnderflow(uint256 totalPending, uint256 amount) public pure {
        vm.assume(amount != 0); // NothingToClaim guard
        vm.assume(amount <= totalPending); // per-account <= total invariant
        uint256 newTotal = totalPending - amount; // line 404
        assert(newTotal < totalPending);
        assert(newTotal + amount == totalPending);
    }
}
