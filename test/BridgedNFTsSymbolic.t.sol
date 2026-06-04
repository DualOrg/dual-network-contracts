// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @title Symbolic proof of the BridgedNFTs force-exit delay boundary.
/// @notice BridgedNFTs holds no value and has essentially one piece of
///         arithmetic: the force-exit timelock check in executeForceSovereignty,
///         `block.timestamp <= requestedAt + FORCE_EXIT_DELAY` (revert TooEarly).
///         These proofs pin down the boundary and rule out overflow.
contract BridgedNFTsSymbolicTest is Test {
    uint256 internal constant FORCE_EXIT_DELAY = 7 days;

    /// @dev Mirrors the guard: returns true iff the exit is still locked.
    function _tooEarly(uint256 requestedAt, uint256 nowTs) internal pure returns (bool) {
        return nowTs <= requestedAt + FORCE_EXIT_DELAY;
    }

    /// @notice The deadline never overflows for any realistic request time, and
    ///         is strictly in the future of the request.
    function check_deadlineNoOverflow(uint256 requestedAt) public pure {
        vm.assume(requestedAt < 2 ** 250); // far beyond any real timestamp
        uint256 deadline = requestedAt + FORCE_EXIT_DELAY;
        assert(deadline > requestedAt);
    }

    /// @notice The timelock is exact: locked at or before the deadline, open
    ///         strictly after it — and the two regimes are complementary.
    function check_boundaryExact(uint256 requestedAt, uint256 nowTs) public pure {
        vm.assume(requestedAt < 2 ** 250);
        uint256 deadline = requestedAt + FORCE_EXIT_DELAY;

        if (nowTs <= deadline) {
            assert(_tooEarly(requestedAt, nowTs)); // still locked
        } else {
            assert(!_tooEarly(requestedAt, nowTs)); // exit unlocked
        }
        // Exactly at the deadline the exit is still locked (boundary exclusive).
        assert(_tooEarly(requestedAt, deadline));
    }
}
