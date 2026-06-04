// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";

contract Sink {
    receive() external payable {}
}

contract FeeDispatcherHandler is Test {
    FeeDispatcher public immutable dispatcher;
    address[3] public sinks;

    uint256 public ghost_directSends;
    uint256 public ghost_emergencyWithdrawn;
    uint256 internal refNonce;

    constructor(FeeDispatcher _d, address[3] memory _sinks) {
        dispatcher = _d;
        sinks = _sinks;
    }

    function _ref() internal returns (bytes32) {
        return keccak256(abi.encode(refNonce++));
    }

    // Handler is the `ledger`, so it may push ledger fees.
    function dispatchLedger(uint256 fee) public {
        fee = bound(fee, 1, 100 ether);
        vm.deal(address(this), address(this).balance + fee);
        try dispatcher.dispatchLedgerFee{value: fee}(_ref(), fee) {} catch {}
    }

    function addRecipient(uint256 sinkSeed, uint256 bps) public {
        address s = sinks[bound(sinkSeed, 0, 2)];
        bps = bound(bps, 1, dispatcher.BPS_DENOMINATOR());
        try dispatcher.addRecipient(payable(s), bps) {} catch {}
    }

    function updateRecipient(uint256 idx, uint256 sinkSeed, uint256 bps) public {
        uint256 count = dispatcher.getRecipientCount();
        if (count == 0) return;
        idx = bound(idx, 0, count - 1);
        address s = sinks[bound(sinkSeed, 0, 2)];
        bps = bound(bps, 1, dispatcher.BPS_DENOMINATOR());
        try dispatcher.updateRecipient(idx, payable(s), bps) {} catch {}
    }

    function removeRecipient(uint256 idx) public {
        uint256 count = dispatcher.getRecipientCount();
        if (count == 0) return;
        idx = bound(idx, 0, count - 1);
        try dispatcher.removeRecipient(idx) {} catch {}
    }

    function directSend(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(dispatcher).call{value: amount}("");
        if (ok) ghost_directSends += amount;
    }

    function emergencyWithdraw(uint256 amount) public {
        uint256 bal = address(dispatcher).balance;
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try dispatcher.emergencyWithdraw(payable(sinks[0]), amount) {
            ghost_emergencyWithdrawn += amount;
        } catch {}
    }

    function pauseToggle() public {
        if (dispatcher.paused()) {
            dispatcher.unpause();
        } else {
            dispatcher.pause();
        }
    }
}

contract FeeDispatcherInvariantTest is Test {
    FeeDispatcher internal dispatcher;
    FeeDispatcherHandler internal handler;

    function setUp() public {
        address[3] memory sinks = [address(new Sink()), address(new Sink()), address(new Sink())];

        FeeDispatcher impl = new FeeDispatcher();
        // owner + ledger predicted as the handler.
        handler = FeeDispatcherHandler(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        dispatcher = FeeDispatcher(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            FeeDispatcher.initialize,
                            (address(handler), makeAddr("vault"), makeAddr("batch"), address(handler))
                        )
                    )
                )
            )
        );
        FeeDispatcherHandler deployed = new FeeDispatcherHandler(dispatcher, sinks);
        require(address(deployed) == address(handler), "handler addr mismatch");

        targetContract(address(handler));
    }

    /// @notice Every dispatched fee is fully accounted as distributed + retained.
    function invariant_dispatchedEqualsDistributedPlusRetained() public view {
        assertEq(
            dispatcher.totalFeesDispatched(),
            dispatcher.totalFeesDistributed() + dispatcher.totalFeesRetained(),
            "dispatched != distributed + retained"
        );
    }

    /// @notice Native conservation: retained fees + direct sends - emergency pulls
    ///         equals the contract balance (no wei created or lost in distribution).
    function invariant_conservation() public view {
        assertEq(
            address(dispatcher).balance,
            dispatcher.totalFeesRetained() + handler.ghost_directSends() - handler.ghost_emergencyWithdrawn(),
            "native not conserved"
        );
    }

    /// @notice Distributed never exceeds dispatched (retained is non-negative).
    function invariant_distributedBounded() public view {
        assertLe(dispatcher.totalFeesDistributed(), dispatcher.totalFeesDispatched(), "distributed > dispatched");
    }

    /// @notice The recipient basis-points sum never exceeds 100% — so a single
    ///         dispatch can never try to distribute more than the fee.
    function invariant_basisPointsSumValid() public view {
        assertLe(dispatcher.totalBasisPoints(), dispatcher.BPS_DENOMINATOR(), "bps sum > 100%");
    }
}
