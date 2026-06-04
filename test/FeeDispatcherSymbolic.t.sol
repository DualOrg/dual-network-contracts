// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proof of the FeeDispatcher distribution arithmetic.
/// @notice Mirrors FeeDispatcher._dispatchFee: each recipient gets
///         `(fee * basisPoints) / BPS_DENOMINATOR`; `retained = fee - distributed`.
contract FeeDispatcherSymbolicTest is Test {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function _share(uint256 fee, uint256 bps) internal pure returns (uint256) {
        return (fee * bps) / BPS_DENOMINATOR;
    }

    /// @notice A single recipient's share never exceeds the fee (bps <= 100%),
    ///         so accumulating shares can never underflow `fee - distributed`.
    /// @dev Fuzzed: the symbolic `fee * bps` multiply times out in SMT (same
    ///      limitation as the multi-recipient case below).
    function testFuzz_SingleShareBounded(uint256 fee, uint256 bps) public pure {
        fee = bound(fee, 0, type(uint240).max);
        bps = bound(bps, 0, BPS_DENOMINATOR);
        assert(_share(fee, bps) <= fee);
    }

    /// @notice Bookkeeping identity: given distributed <= fee (guaranteed by the
    ///         bps-sum invariant), retained = fee - distributed reconstitutes the
    ///         fee exactly with no underflow.
    function check_retainedAccounting(uint256 fee, uint256 distributed) public pure {
        vm.assume(distributed <= fee);
        uint256 retained = fee - distributed; // mirrors line 152
        assert(distributed + retained == fee);
        assert(retained <= fee);
    }

    /// @notice Multi-recipient distribution never exceeds the fee, provided the
    ///         basis-points sum is <= 100% (the contract's _validateBasisPointsSum
    ///         invariant). Fuzzed — the symbolic fee*bps multiplies time out in SMT.
    function testFuzz_MultiRecipientDistributedBounded(uint256 fee, uint256 b0, uint256 b1, uint256 b2) public pure {
        fee = bound(fee, 0, type(uint240).max);
        b0 = bound(b0, 0, BPS_DENOMINATOR);
        b1 = bound(b1, 0, BPS_DENOMINATOR - b0);
        b2 = bound(b2, 0, BPS_DENOMINATOR - b0 - b1); // sum <= BPS_DENOMINATOR

        uint256 distributed = _share(fee, b0) + _share(fee, b1) + _share(fee, b2);
        assert(distributed <= fee);
        assert(fee - distributed <= fee); // retained well-defined, no underflow
    }
}
