// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ledger} from "../src/Ledger.sol";
import {IFeeDispatcher} from "../src/interfaces/IFeeDispatcher.sol";
import {ILedger} from "../src/interfaces/ILedger.sol";

contract MockFeeDispatcher is IFeeDispatcher {
    struct LedgerFeeCall {
        bytes32 sourceId;
        uint256 fee;
        uint256 value;
    }

    LedgerFeeCall[] public ledgerCalls;
    bool public shouldFail;

    function setShouldFail(bool value) external {
        shouldFail = value;
    }

    function dispatchFee(bytes32, uint256) external pure override returns (bool) {
        return true;
    }

    function dispatchLedgerFee(bytes32 sourceId, uint256 fee) external payable override returns (bool) {
        ledgerCalls.push(LedgerFeeCall({sourceId: sourceId, fee: fee, value: msg.value}));
        return !shouldFail;
    }

    function ledgerCallCount() external view returns (uint256) {
        return ledgerCalls.length;
    }
}

contract LedgerTest is Test {
    Ledger ledger;
    MockFeeDispatcher feeDispatcher;

    address admin = makeAddr("admin");
    address sender = makeAddr("sender");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SplitUpdated(uint256 oldFeeDispatcherBps, uint256 newFeeDispatcherBps);

    function _deployLedger(address _admin, address _dispatcher, address _sender, address _treasury)
        internal
        returns (Ledger)
    {
        Ledger impl = new Ledger();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Ledger.initialize, (_admin, _dispatcher, _sender, _treasury))
        );
        return Ledger(payable(address(proxy)));
    }

    function _ref(uint256 refId) internal pure returns (bytes32) {
        return bytes32(uint256(refId));
    }

    function _single(uint256 refId, uint256 fee) internal view returns (ILedger.SingleFeeParams memory) {
        return ILedger.SingleFeeParams({refId: _ref(refId), tokenId: 42, fee: fee, timestamp: block.timestamp});
    }

    function _snapshot(uint256 refId, uint256 fee) internal view returns (ILedger.SnapshotFeeParams memory) {
        return ILedger.SnapshotFeeParams({
            refId: _ref(refId),
            from: keccak256("snapshot-from"),
            to: keccak256("snapshot-to"),
            entriesCount: 3,
            fee: fee,
            digest: keccak256("snapshot")
        });
    }

    function setUp() public {
        vm.warp(2 hours);
        feeDispatcher = new MockFeeDispatcher();
        ledger = _deployLedger(admin, address(feeDispatcher), sender, treasury);
    }

    function test_Initialize_SetsConfigAndRoles() public view {
        assertEq(ledger.owner(), admin);
        assertEq(address(ledger.feeDispatcher()), address(feeDispatcher));
        assertEq(ledger.treasury(), treasury);
        assertEq(ledger.feeDispatcherBps(), 5_000);
        assertFalse(ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(ledger.hasRole(ledger.SENDER_ROLE(), sender));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        Ledger impl = new Ledger();
        vm.expectRevert(Ledger.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(Ledger.initialize, (address(0), address(feeDispatcher), sender, treasury))
        );
    }

    function test_Initialize_RevertsOnZeroSender() public {
        Ledger impl = new Ledger();
        vm.expectRevert(Ledger.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(Ledger.initialize, (admin, address(feeDispatcher), address(0), treasury))
        );
    }

    function test_Initialize_RevertsOnZeroTreasury() public {
        Ledger impl = new Ledger();
        vm.expectRevert(Ledger.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl), abi.encodeCall(Ledger.initialize, (admin, address(feeDispatcher), sender, address(0)))
        );
    }

    function test_Deposit_OnlyOwnerAndTracksTotal() public {
        vm.deal(admin, 2 ether);
        vm.prank(admin);
        ledger.deposit{value: 2 ether}();

        assertEq(address(ledger).balance, 2 ether);
        assertEq(ledger.totalDeposited(), 2 ether);
    }

    function test_Deposit_RevertsFromNonOwner() public {
        vm.deal(alice, 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        ledger.deposit{value: 1 ether}();
    }

    function test_ProcessSingleFee_SplitsAndRecords() public {
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();

        uint256 treasuryBefore = treasury.balance;

        vm.prank(sender);
        ledger.processSingleFee(_single(99, 1 ether));

        assertTrue(ledger.processedRefIds(_ref(99)));
        assertEq(ledger.totalRecords(), 1);
        assertEq(ledger.totalSingleRecords(), 1);
        assertEq(ledger.totalFees(), 1 ether);
        assertEq(ledger.dispatchedFees(), 0.5 ether);
        assertEq(ledger.treasuryFees(), 0.5 ether);
        assertEq(treasury.balance - treasuryBefore, 0.5 ether);
        assertEq(feeDispatcher.ledgerCallCount(), 1);

        (bytes32 sourceId, uint256 fee, uint256 value) = feeDispatcher.ledgerCalls(0);
        assertEq(sourceId, _ref(99));
        assertEq(fee, 0.5 ether);
        assertEq(value, 0.5 ether);
    }

    function test_ProcessSingleFee_RevertsOnDuplicateRefId() public {
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();

        vm.prank(sender);
        ledger.processSingleFee(_single(99, 0));

        vm.expectRevert(Ledger.DuplicateRefId.selector);
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 0));
    }

    function test_ProcessSingleFee_RevertsWhenFeeDispatcherUnsetWithDispatcherShare() public {
        vm.deal(admin, 1 ether);
        vm.startPrank(admin);
        ledger.deposit{value: 1 ether}();
        ledger.setFeeDispatcher(address(0));
        vm.stopPrank();

        vm.expectRevert(Ledger.FeeDispatcherNotSet.selector);
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 1 ether));

        assertFalse(ledger.processedRefIds(_ref(99)));
        assertEq(ledger.totalFees(), 0);
    }

    function test_ProcessSingleFee_AllowsZeroDispatcherWhenSplitIsTreasuryOnly() public {
        vm.deal(admin, 1 ether);
        vm.startPrank(admin);
        ledger.deposit{value: 1 ether}();
        ledger.setFeeDispatcher(address(0));
        ledger.setSplit(0);
        vm.stopPrank();

        uint256 treasuryBefore = treasury.balance;
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 1 ether));

        assertEq(treasury.balance - treasuryBefore, 1 ether);
        assertEq(ledger.dispatchedFees(), 0);
        assertEq(ledger.treasuryFees(), 1 ether);
    }

    function test_ProcessSingleFee_RevertsWhenDispatcherReturnsFalse() public {
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();
        feeDispatcher.setShouldFail(true);

        vm.expectRevert(Ledger.TransferFailed.selector);
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 1 ether));

        assertFalse(ledger.processedRefIds(_ref(99)));
        assertEq(ledger.totalFees(), 0);
    }

    function test_ProcessSingleFee_RevertsOnInsufficientBalance() public {
        vm.expectRevert(Ledger.InsufficientBalance.selector);
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 1 ether));
    }

    function test_ProcessSingleFee_RevertsWithoutSenderRole() public {
        vm.expectRevert();
        vm.prank(alice);
        ledger.processSingleFee(_single(99, 0));
    }

    function test_ProcessSnapshotFee_RecordsSnapshot() public {
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();

        vm.prank(sender);
        ledger.processSnapshotFee(_snapshot(100, 1 ether));

        assertTrue(ledger.processedRefIds(_ref(100)));
        assertEq(ledger.totalRecords(), 3);
        assertEq(ledger.totalSnapshots(), 1);
        assertEq(ledger.totalFees(), 1 ether);
    }

    function test_ProcessSnapshotFee_RevertsOnZeroEntries() public {
        ILedger.SnapshotFeeParams memory params = _snapshot(100, 0);
        params.entriesCount = 0;

        vm.expectRevert(Ledger.InvalidEntriesCount.selector);
        vm.prank(sender);
        ledger.processSnapshotFee(params);
    }

    function test_SetFeeDispatcher_UpdatesAddress() public {
        address newDispatcher = makeAddr("newDispatcher");
        vm.expectEmit(true, true, false, false);
        emit FeeDispatcherUpdated(address(feeDispatcher), newDispatcher);
        vm.prank(admin);
        ledger.setFeeDispatcher(newDispatcher);

        assertEq(address(ledger.feeDispatcher()), newDispatcher);
    }

    function test_SetTreasury_UpdatesAddress() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(treasury, newTreasury);
        vm.prank(admin);
        ledger.setTreasury(newTreasury);

        assertEq(ledger.treasury(), newTreasury);
    }

    function test_SetSplit_UpdatesSplit() public {
        vm.expectEmit(false, false, false, true);
        emit SplitUpdated(5_000, 2_500);
        vm.prank(admin);
        ledger.setSplit(2_500);

        assertEq(ledger.feeDispatcherBps(), 2_500);
    }

    function test_SetSplit_RevertsOnInvalidBps() public {
        vm.expectRevert(Ledger.InvalidBps.selector);
        vm.prank(admin);
        ledger.setSplit(10_001);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        ledger.withdraw(alice, 1 ether);
    }

    function test_Withdraw_SendsFunds() public {
        vm.deal(admin, 1 ether);
        vm.startPrank(admin);
        ledger.deposit{value: 1 ether}();

        uint256 beforeBalance = admin.balance;
        ledger.withdraw(admin, 1 ether);
        vm.stopPrank();

        assertEq(admin.balance - beforeBalance, 1 ether);
        assertEq(address(ledger).balance, 0);
    }

    function test_GrantSenderRole_OnlyOwnerAndRejectsZero() public {
        vm.expectRevert(Ledger.ZeroAddress.selector);
        vm.prank(admin);
        ledger.grantSenderRole(address(0));

        vm.expectRevert();
        vm.prank(alice);
        ledger.grantSenderRole(alice);

        vm.prank(admin);
        ledger.grantSenderRole(alice);
        assertTrue(ledger.hasRole(ledger.SENDER_ROLE(), alice));
    }

    function test_Pause_BlocksDepositAndProcessing() public {
        vm.prank(admin);
        ledger.pause();

        vm.deal(admin, 1 ether);
        vm.expectRevert();
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();

        vm.expectRevert();
        vm.prank(sender);
        ledger.processSingleFee(_single(99, 0));
    }

    // ── coverage: revert/edge paths ───────────────────────────────────────────

    function test_Deposit_RevertsOnZeroValue() public {
        vm.expectRevert(Ledger.ZeroAmount.selector);
        vm.prank(admin);
        ledger.deposit{value: 0}();
    }

    function test_ProcessSnapshotFee_RevertsOnDuplicateRefId() public {
        vm.deal(admin, 2 ether);
        vm.prank(admin);
        ledger.deposit{value: 2 ether}();

        vm.prank(sender);
        ledger.processSnapshotFee(_snapshot(7, 1 ether));

        vm.expectRevert(Ledger.DuplicateRefId.selector);
        vm.prank(sender);
        ledger.processSnapshotFee(_snapshot(7, 1 ether));
    }

    function test_DispatchFee_RevertsWhenTreasuryRejects() public {
        // 50/50 split → treasury leg is non-zero; point it at a rejecting sink.
        RejectingTreasury bad = new RejectingTreasury();
        vm.prank(admin);
        ledger.setTreasury(address(bad));

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        ledger.deposit{value: 1 ether}();

        vm.expectRevert(Ledger.TransferFailed.selector);
        vm.prank(sender);
        ledger.processSingleFee(_single(50, 1 ether));
    }

    function test_SetFeeDispatcher_RevertsOnUnchangedValue() public {
        vm.expectRevert(Ledger.UnchangedValue.selector);
        vm.prank(admin);
        ledger.setFeeDispatcher(address(feeDispatcher));
    }

    function test_SetTreasury_RevertsOnZeroAndUnchanged() public {
        vm.expectRevert(Ledger.ZeroAddress.selector);
        vm.prank(admin);
        ledger.setTreasury(address(0));

        vm.expectRevert(Ledger.UnchangedValue.selector);
        vm.prank(admin);
        ledger.setTreasury(treasury);
    }

    function test_SetSplit_RevertsOnUnchangedValue() public {
        uint256 current = ledger.feeDispatcherBps();
        vm.expectRevert(Ledger.UnchangedValue.selector);
        vm.prank(admin);
        ledger.setSplit(current);
    }

    function test_Withdraw_RevertsOnZeroAddressAmountAndInsufficient() public {
        vm.startPrank(admin);
        vm.expectRevert(Ledger.ZeroAddress.selector);
        ledger.withdraw(address(0), 1 ether);

        vm.expectRevert(Ledger.ZeroAmount.selector);
        ledger.withdraw(admin, 0);

        vm.expectRevert(Ledger.InsufficientBalance.selector);
        ledger.withdraw(admin, 1 ether); // balance is 0
        vm.stopPrank();
    }

    function test_Withdraw_RevertsWhenRecipientRejects() public {
        RejectingTreasury bad = new RejectingTreasury();
        vm.deal(admin, 1 ether);
        vm.startPrank(admin);
        ledger.deposit{value: 1 ether}();
        vm.expectRevert(Ledger.TransferFailed.selector);
        ledger.withdraw(address(bad), 1 ether);
        vm.stopPrank();
    }

    function test_Unpause_ReenablesDeposit() public {
        vm.startPrank(admin);
        ledger.pause();
        ledger.unpause();
        vm.deal(admin, 1 ether);
        ledger.deposit{value: 1 ether}();
        vm.stopPrank();
        assertEq(ledger.totalDeposited(), 1 ether);
    }
}

contract RejectingTreasury {
    receive() external payable {
        revert("no");
    }
}
