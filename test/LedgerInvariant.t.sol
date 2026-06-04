// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ledger} from "../src/Ledger.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";

/// @dev Sink that accepts and records native pushed via dispatchLedgerFee.
contract DispatcherSink is IFeeDispatcher {
    uint256 public received;
    bool public shouldFail;

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

    function dispatchFee(bytes32, uint256) external pure override returns (bool) {
        return true;
    }

    function dispatchLedgerFee(bytes32, uint256) external payable override returns (bool) {
        if (shouldFail) return false;
        received += msg.value;
        return true;
    }
}

/// @dev Plain native sink for the treasury leg.
contract TreasurySink {
    receive() external payable {}
}

contract LedgerHandler is Test {
    Ledger public immutable ledger;
    DispatcherSink public immutable dispatcher;
    TreasurySink public immutable treasury;

    uint256 public ghost_withdrawn;
    uint256 public ghost_snapshotEntries;
    uint256 public ghost_snapshotCount;
    uint256 internal refNonce;

    constructor(Ledger _ledger, DispatcherSink _dispatcher, TreasurySink _treasury) {
        ledger = _ledger;
        dispatcher = _dispatcher;
        treasury = _treasury;
    }

    function _nextRef() internal returns (bytes32) {
        return keccak256(abi.encode("ref", refNonce++));
    }

    function deposit(uint256 amount) public {
        amount = bound(amount, 1, 1_000 ether);
        vm.deal(address(this), address(this).balance + amount);
        ledger.deposit{value: amount}();
    }

    function processSingle(uint256 fee) public {
        fee = bound(fee, 0, address(ledger).balance);
        ILedger.SingleFeeParams memory p =
            ILedger.SingleFeeParams({refId: _nextRef(), tokenId: 1, fee: fee, timestamp: block.timestamp});
        try ledger.processSingleFee(p) {} catch {}
    }

    function processSnapshot(uint256 fee, uint256 entries) public {
        fee = bound(fee, 0, address(ledger).balance);
        entries = bound(entries, 1, 1000);
        ILedger.SnapshotFeeParams memory p = ILedger.SnapshotFeeParams({
            refId: _nextRef(),
            from: keccak256("from"),
            to: keccak256("to"),
            entriesCount: entries,
            fee: fee,
            digest: keccak256("d")
        });
        try ledger.processSnapshotFee(p) {
            ghost_snapshotEntries += entries;
            ghost_snapshotCount += 1;
        } catch {}
    }

    function withdraw(uint256 amount) public {
        uint256 bal = address(ledger).balance;
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try ledger.withdraw(address(treasury), amount) {
            ghost_withdrawn += amount;
        } catch {}
    }

    function setSplit(uint256 bps) public {
        bps = bound(bps, 0, ledger.BPS_DENOMINATOR());
        try ledger.setSplit(bps) {} catch {}
    }

    function pauseToggle() public {
        if (ledger.paused()) {
            ledger.unpause();
        } else {
            ledger.pause();
        }
    }
}

contract LedgerInvariantTest is Test {
    Ledger internal ledger;
    LedgerHandler internal handler;
    DispatcherSink internal dispatcher;
    TreasurySink internal treasury;

    function setUp() public {
        vm.warp(1_000_000);
        dispatcher = new DispatcherSink();
        treasury = new TreasurySink();

        // Predict the handler address so it is admin + sender from genesis.
        Ledger impl = new Ledger();
        handler = LedgerHandler(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        ledger = Ledger(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            Ledger.initialize,
                            (address(handler), address(dispatcher), address(handler), address(treasury))
                        )
                    )
                )
            )
        );
        LedgerHandler deployed = new LedgerHandler(ledger, dispatcher, treasury);
        require(address(deployed) == address(handler), "handler addr mismatch");

        targetContract(address(handler));
    }

    /// @notice Native conservation: every deposited wei is either still held, was
    ///         paid out as a fee (dispatcher + treasury legs), or was withdrawn.
    function invariant_conservation() public view {
        uint256 accountedOut = ledger.dispatchedFees() + ledger.treasuryFees() + handler.ghost_withdrawn();
        assertEq(address(ledger).balance + accountedOut, ledger.totalDeposited(), "native not conserved");
    }

    /// @notice The fee split is lossless: dispatcher + treasury shares sum to the
    ///         total fees processed (no wei created or lost in the split).
    function invariant_splitLossless() public view {
        assertEq(ledger.dispatchedFees() + ledger.treasuryFees(), ledger.totalFees(), "split lossy");
    }

    /// @notice Record accounting matches the inputs: single records + snapshot
    ///         entries reconcile with totalRecords; snapshot count matches.
    function invariant_recordsConsistent() public view {
        assertEq(
            ledger.totalRecords(),
            ledger.totalSingleRecords() + handler.ghost_snapshotEntries(),
            "totalRecords mismatch"
        );
        assertEq(ledger.totalSnapshots(), handler.ghost_snapshotCount(), "snapshot count mismatch");
    }

    /// @notice Per-leg fee totals never exceed the grand total.
    function invariant_feesBounded() public view {
        assertLe(ledger.dispatchedFees(), ledger.totalFees(), "dispatched > total");
        assertLe(ledger.treasuryFees(), ledger.totalFees(), "treasury > total");
    }

    /// @notice The Ledger can never owe more than it holds: a fee is only ever
    ///         dispatched when the balance covered it.
    function invariant_balanceBacksDeposits() public view {
        assertGe(ledger.totalDeposited(), ledger.dispatchedFees() + ledger.treasuryFees() + handler.ghost_withdrawn());
    }
}
