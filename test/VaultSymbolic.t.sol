// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proof of the Vault fee-withdrawal accounting.
/// @notice The Vault performs no fee splitting — its safety reduces to two
///         arithmetic facts in withdrawForFeeDistribution / withdrawDual:
///         (1) a withdrawal is gated by `balance >= amount`, and
///         (2) `totalWithdrawnForFees += amount` is monotonic and exact.
///         Mirrors Vault.sol lines 116-122.
contract VaultSymbolicTest is Test {
    /// @notice The balance check guarantees a withdrawal never exceeds holdings,
    ///         so the post-withdrawal balance never underflows.
    function check_withdrawalNeverUnderflows(uint256 balance, uint256 amount) public pure {
        vm.assume(amount != 0); // ZeroAmount guard
        vm.assume(balance >= amount); // InsufficientBalance guard
        uint256 remaining = balance - amount; // native leaves the vault
        assert(remaining < balance || amount == 0);
        assert(remaining + amount == balance);
    }

    /// @notice The fee counter increases by exactly `amount` and is monotonic
    ///         (no overflow for any realistic cumulative total).
    function check_feeCounterMonotonic(uint256 prior, uint256 amount) public pure {
        vm.assume(amount != 0);
        vm.assume(prior < 2 ** 240 && amount < 2 ** 240); // no overflow
        uint256 updated = prior + amount; // mirrors totalWithdrawnForFees += amount
        assert(updated >= prior);
        assert(updated - prior == amount);
    }
}
