// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proof of the Ledger fee-split arithmetic.
/// @notice `split` is a FAITHFUL MIRROR of Ledger._dispatchFee lines 175-176:
///         toDispatcher = (fee * feeDispatcherBps) / BPS_DENOMINATOR;
///         toTreasury   = fee - toDispatcher;
///         Proven for symbolic `fee` and `bps`: the split is lossless and neither
///         leg can underflow or exceed the fee. The divisor is the constant
///         BPS_DENOMINATOR, so these discharge quickly.
contract LedgerSymbolicTest is Test {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function split(uint256 fee, uint256 bps) internal pure returns (uint256 toDispatcher, uint256 toTreasury) {
        toDispatcher = (fee * bps) / BPS_DENOMINATOR;
        toTreasury = fee - toDispatcher;
    }

    function _assume(uint256 fee, uint256 bps) internal pure {
        // setSplit enforces bps <= BPS_DENOMINATOR.
        vm.assume(bps <= BPS_DENOMINATOR);
        // Avoid overflow on fee * bps (fee is native wei; 2^240 dwarfs any supply).
        vm.assume(fee < 2 ** 240);
    }

    /// @notice LOSSLESS: the two legs always sum back to exactly the fee.
    function check_splitLossless(uint256 fee, uint256 bps) public pure {
        _assume(fee, bps);
        (uint256 d, uint256 t) = split(fee, bps);
        assert(d + t == fee);
    }

    /// @notice NO UNDERFLOW / BOUNDS: each leg is within [0, fee]; in particular
    ///         `fee - toDispatcher` never underflows because toDispatcher <= fee
    ///         whenever bps <= BPS_DENOMINATOR.
    function check_shareBounds(uint256 fee, uint256 bps) public pure {
        _assume(fee, bps);
        (uint256 d, uint256 t) = split(fee, bps);
        assert(d <= fee);
        assert(t <= fee);
    }

    /// @notice The dispatcher leg never exceeds the requested share of the fee.
    /// @dev Verified by FUZZING: the `fee * bps` symbolic×symbolic multiply makes
    ///      this intractable for the SMT solver (times out). Fuzzing covers it.
    function testFuzz_DispatcherShareWithinBps(uint256 fee, uint256 bps) public pure {
        fee = bound(fee, 0, type(uint240).max);
        bps = bound(bps, 0, BPS_DENOMINATOR);
        (uint256 d,) = split(fee, bps);
        assert(d * BPS_DENOMINATOR <= fee * bps);
    }

    /// @notice A full-share (bps == DENOM) routes everything to the dispatcher and
    ///         nothing to treasury; a zero share does the inverse. Boundary check.
    /// @dev Fuzzed: the (x*c)/c == x division reasoning times out symbolically.
    function testFuzz_BoundaryShares(uint256 fee) public pure {
        fee = bound(fee, 0, type(uint240).max);
        (uint256 dFull, uint256 tFull) = split(fee, BPS_DENOMINATOR);
        assert(dFull == fee && tFull == 0);
        (uint256 dZero, uint256 tZero) = split(fee, 0);
        assert(dZero == 0 && tZero == fee);
    }
}
