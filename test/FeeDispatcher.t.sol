// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeDispatcher} from "../src/FeeDispatcher.sol";
import {Vault} from "../src/Vault.sol";
import {FeeSource} from "../src/libraries/FeeSource.sol";

contract FeeDispatcherTest is Test {
    FeeDispatcher dispatcher;
    Vault vault;

    address owner = makeAddr("owner");
    address batchRegistryAddr = makeAddr("batchRegistry");
    address ledgerAddr = makeAddr("ledger");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    event FeeDispatched(bytes32 indexed sourceId, uint8 indexed sourceType, uint256 distributed, uint256 retained);
    event FeeDistributed(address indexed recipient, uint256 amount, bytes32 indexed sourceId);
    event FeeDistributionFailed(address indexed recipient, uint256 amount, bytes32 indexed sourceId);
    event FeeWithdrawalFailed(bytes32 indexed sourceId, uint8 sourceType, uint256 fee);
    event FeesRetained(uint256 amount, bytes32 indexed sourceId);
    event RecipientAdded(address indexed recipient, uint256 basisPoints, uint256 index);
    event RecipientUpdated(uint256 indexed index, address indexed recipient, uint256 basisPoints);
    event RecipientRemoved(uint256 indexed index, address indexed recipient);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event BatchRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event LedgerUpdated(address indexed oldLedger, address indexed newLedger);
    event EmergencyWithdrawal(address indexed to, uint256 amount);

    function _deployVault() internal returns (Vault) {
        Vault impl = new Vault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (owner)));
        return Vault(payable(address(proxy)));
    }

    function _deployFeeDispatcher(address _vault, address _batchRegistry, address _ledger)
        internal
        returns (FeeDispatcher)
    {
        FeeDispatcher impl = new FeeDispatcher();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(FeeDispatcher.initialize, (owner, _vault, _batchRegistry, _ledger))
        );
        return FeeDispatcher(payable(address(proxy)));
    }

    function setUp() public {
        vault = _deployVault();
        dispatcher = _deployFeeDispatcher(address(vault), batchRegistryAddr, ledgerAddr);

        // Authorize FeeDispatcher as the sole fee withdrawer on Vault
        vm.prank(owner);
        vault.setFeeDispatcher(address(dispatcher));

        // Fund the vault with ETH
        vm.deal(address(vault), 10 ether);
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_Initialize_SetsAddresses() public view {
        assertEq(dispatcher.vault(), address(vault));
        assertEq(dispatcher.batchRegistry(), batchRegistryAddr);
        assertEq(dispatcher.ledger(), ledgerAddr);
        assertEq(dispatcher.owner(), owner);
    }

    function test_Initialize_RevertsOnZeroOwner() public {
        FeeDispatcher impl = new FeeDispatcher();
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(FeeDispatcher.initialize, (address(0), address(vault), batchRegistryAddr, ledgerAddr))
        );
    }

    // ── addRecipient ─────────────────────────────────────────────────────────

    function test_AddRecipient_Succeeds() public {
        vm.expectEmit(true, false, false, true);
        emit RecipientAdded(treasury, 5000, 0);
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000);

        assertEq(dispatcher.getRecipientCount(), 1);
        assertEq(dispatcher.totalBasisPoints(), 5000);
    }

    function test_AddRecipient_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.addRecipient(payable(address(0)), 5000);
    }

    function test_AddRecipient_RevertsOnZeroBasisPoints() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.InvalidBasisPoints.selector);
        dispatcher.addRecipient(payable(treasury), 0);
    }

    function test_AddRecipient_RevertsWhenBasisPointsExceeded() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 6000);

        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.BasisPointsExceeded.selector);
        dispatcher.addRecipient(payable(alice), 5000); // 6000 + 5000 > 10000
    }

    function test_AddRecipient_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        dispatcher.addRecipient(payable(treasury), 5000);
    }

    function test_TotalBasisPoints_SumsCorrectly() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000);
        vm.prank(owner);
        dispatcher.addRecipient(payable(alice), 3000);

        assertEq(dispatcher.totalBasisPoints(), 8000);
    }

    // ── updateRecipient ──────────────────────────────────────────────────────

    function test_UpdateRecipient_Succeeds() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000);

        address newRecipient = makeAddr("newRecipient");
        vm.expectEmit(true, true, false, true);
        emit RecipientUpdated(0, newRecipient, 7000);
        vm.prank(owner);
        dispatcher.updateRecipient(0, payable(newRecipient), 7000);

        FeeDispatcher.FeeRecipient[] memory r = dispatcher.getRecipients();
        assertEq(r[0].recipient, newRecipient);
        assertEq(r[0].basisPoints, 7000);
    }

    function test_UpdateRecipient_RevertsOnInvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.InvalidIndex.selector);
        dispatcher.updateRecipient(0, payable(treasury), 5000);
    }

    function test_UpdateRecipient_RevertsOnZeroAddress() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000);

        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.updateRecipient(0, payable(address(0)), 5000);
    }

    // ── removeRecipient ──────────────────────────────────────────────────────

    function test_RemoveRecipient_Succeeds() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000);
        assertEq(dispatcher.getRecipientCount(), 1);

        vm.expectEmit(true, true, false, false);
        emit RecipientRemoved(0, treasury);
        vm.prank(owner);
        dispatcher.removeRecipient(0);

        assertEq(dispatcher.getRecipientCount(), 0);
    }

    function test_RemoveRecipient_SwapsWithLast() public {
        address second = makeAddr("second");
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 4000);
        vm.prank(owner);
        dispatcher.addRecipient(payable(second), 3000);

        // Remove first; second should move to index 0
        vm.prank(owner);
        dispatcher.removeRecipient(0);

        assertEq(dispatcher.getRecipientCount(), 1);
        FeeDispatcher.FeeRecipient[] memory r = dispatcher.getRecipients();
        assertEq(r[0].recipient, second);
    }

    function test_RemoveRecipient_RevertsOnInvalidIndex() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.InvalidIndex.selector);
        dispatcher.removeRecipient(0);
    }

    // ── dispatchFee ──────────────────────────────────────────────────────────

    function test_DispatchFee_DistributesToRecipients() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 10000); // 100%

        bytes32 batchHash = keccak256("batch1");
        uint256 fee = 1 ether;

        uint256 balBefore = treasury.balance;
        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(batchHash, fee);

        assertEq(treasury.balance - balBefore, fee);
        assertEq(dispatcher.totalFeesDispatched(), fee);
        assertEq(dispatcher.totalFeesDistributed(), fee);
    }

    function test_DispatchFee_SplitsBetweenRecipients() public {
        address secondRecipient = makeAddr("second");
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 7000); // 70%
        vm.prank(owner);
        dispatcher.addRecipient(payable(secondRecipient), 3000); // 30%

        uint256 fee = 1 ether;
        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(keccak256("batch"), fee);

        assertEq(treasury.balance, 0.7 ether);
        assertEq(secondRecipient.balance, 0.3 ether);
    }

    function test_DispatchFee_RetainsUnallocatedFees() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 5000); // 50%

        uint256 fee = 1 ether;
        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(keccak256("batch"), fee);

        assertEq(treasury.balance, 0.5 ether);
        assertEq(dispatcher.totalFeesRetained(), 0.5 ether);
    }

    function test_DispatchFee_DoesNothingOnZeroFee() public {
        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(keccak256("batch"), 0); // Should not revert
        assertEq(dispatcher.totalFeesDispatched(), 0);
    }

    function test_DispatchFee_RevertsFromUnauthorized() public {
        vm.expectRevert(FeeDispatcher.Unauthorized.selector);
        vm.prank(alice);
        dispatcher.dispatchFee(keccak256("batch"), 1 ether);
    }

    function test_DispatchFee_EmitsFeeWithdrawalFailedWhenVaultEmpty() public {
        // Drain the vault
        vm.prank(owner);
        vault.withdrawDual(owner, 10 ether);

        bytes32 batchHash = keccak256("batch");
        vm.expectEmit(true, true, false, true);
        emit FeeWithdrawalFailed(batchHash, FeeSource.BATCH, 1 ether);
        vm.prank(batchRegistryAddr);
        bool success = dispatcher.dispatchFee(batchHash, 1 ether);

        assertFalse(success);
        assertEq(dispatcher.totalFeesDispatched(), 0);
        assertEq(dispatcher.totalFeesDistributed(), 0);
    }

    function test_DispatchFee_ReturnsTrueWhenWithdrawalSucceeds() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 10000);

        vm.prank(batchRegistryAddr);
        bool success = dispatcher.dispatchFee(keccak256("batch"), 1 ether);

        assertTrue(success);
    }

    // ── dispatchLedgerFee ────────────────────────────────────────────────────

    function test_DispatchLedgerFee_DistributesToRecipients() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 10000);

        vm.deal(ledgerAddr, 0.5 ether);
        uint256 balBefore = treasury.balance;
        vm.prank(ledgerAddr);
        dispatcher.dispatchLedgerFee{value: 0.5 ether}(bytes32(uint256(123)), 0.5 ether);

        assertEq(treasury.balance - balBefore, 0.5 ether);
        assertEq(dispatcher.totalFeesDispatched(), 0.5 ether);
    }

    function test_DispatchLedgerFee_RevertsFromUnauthorized() public {
        vm.deal(alice, 0.5 ether);
        vm.expectRevert(FeeDispatcher.Unauthorized.selector);
        vm.prank(alice);
        dispatcher.dispatchLedgerFee{value: 0.5 ether}(bytes32(uint256(1)), 0.5 ether);
    }

    function test_DispatchLedgerFee_DoesNothingOnZeroFee() public {
        vm.prank(ledgerAddr);
        dispatcher.dispatchLedgerFee(bytes32(uint256(99)), 0);
        assertEq(dispatcher.totalFeesDispatched(), 0);
    }

    function test_DispatchLedgerFee_RevertsOnValueMismatch() public {
        vm.deal(ledgerAddr, 0.5 ether);
        vm.expectRevert(FeeDispatcher.ZeroAmount.selector);
        vm.prank(ledgerAddr);
        dispatcher.dispatchLedgerFee{value: 0.4 ether}(bytes32(uint256(99)), 0.5 ether);
    }

    // ── setters ───────────────────────────────────────────────────────────────

    function test_SetVault_UpdatesAddress() public {
        address newVault = makeAddr("newVault");
        vm.expectEmit(true, true, false, false);
        emit VaultUpdated(address(vault), newVault);
        vm.prank(owner);
        dispatcher.setVault(newVault);

        assertEq(dispatcher.vault(), newVault);
    }

    function test_SetVault_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.setVault(address(0));
    }

    function test_SetVault_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.UnchangedValue.selector);
        dispatcher.setVault(address(vault));
    }

    function test_SetVault_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        dispatcher.setVault(makeAddr("newVault"));
    }

    function test_SetBatchRegistry_UpdatesAddress() public {
        address newRegistry = makeAddr("newRegistry");
        vm.expectEmit(true, true, false, false);
        emit BatchRegistryUpdated(batchRegistryAddr, newRegistry);
        vm.prank(owner);
        dispatcher.setBatchRegistry(newRegistry);

        assertEq(dispatcher.batchRegistry(), newRegistry);
    }

    function test_SetBatchRegistry_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.UnchangedValue.selector);
        dispatcher.setBatchRegistry(batchRegistryAddr);
    }

    function test_SetLedger_UpdatesAddress() public {
        address newLedger = makeAddr("newLedger");
        vm.expectEmit(true, true, false, false);
        emit LedgerUpdated(ledgerAddr, newLedger);
        vm.prank(owner);
        dispatcher.setLedger(newLedger);

        assertEq(dispatcher.ledger(), newLedger);
    }

    function test_SetLedger_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.UnchangedValue.selector);
        dispatcher.setLedger(ledgerAddr);
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_Pause_BlocksDispatch() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 10000);
        vm.prank(owner);
        dispatcher.pause();

        vm.expectRevert();
        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(keccak256("batch"), 1 ether);
    }

    function test_Unpause_AllowsDispatch() public {
        vm.prank(owner);
        dispatcher.addRecipient(payable(treasury), 10000);
        vm.prank(owner);
        dispatcher.pause();
        vm.prank(owner);
        dispatcher.unpause();

        vm.prank(batchRegistryAddr);
        dispatcher.dispatchFee(keccak256("batch"), 1 ether);
        // no revert
    }

    // ── emergencyWithdraw ─────────────────────────────────────────────────────

    function test_EmergencyWithdraw_Succeeds() public {
        vm.deal(address(dispatcher), 1 ether);
        uint256 balBefore = owner.balance;

        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawal(owner, 0.5 ether);
        vm.prank(owner);
        dispatcher.emergencyWithdraw(payable(owner), 0.5 ether);

        assertEq(owner.balance - balBefore, 0.5 ether);
    }

    function test_EmergencyWithdraw_RevertsOnZeroAddress() public {
        vm.deal(address(dispatcher), 1 ether);
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.emergencyWithdraw(payable(address(0)), 0.5 ether);
    }

    function test_EmergencyWithdraw_RevertsOnInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(FeeDispatcher.InsufficientBalance.selector);
        dispatcher.emergencyWithdraw(payable(owner), 1 ether);
    }

    function test_EmergencyWithdraw_RevertsFromNonOwner() public {
        vm.deal(address(dispatcher), 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        dispatcher.emergencyWithdraw(payable(alice), 0.5 ether);
    }

    // ── coverage: revert/edge paths ───────────────────────────────────────────

    function test_UpdateRecipient_RevertsOnInvalidBps() public {
        vm.startPrank(owner);
        dispatcher.addRecipient(payable(alice), 1000);
        vm.expectRevert(FeeDispatcher.InvalidBasisPoints.selector);
        dispatcher.updateRecipient(0, payable(alice), 0);
        vm.stopPrank();
    }

    function test_SetBatchRegistry_RevertsOnZeroAndUnchanged() public {
        vm.startPrank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.setBatchRegistry(address(0));
        vm.expectRevert(FeeDispatcher.UnchangedValue.selector);
        dispatcher.setBatchRegistry(batchRegistryAddr);
        vm.stopPrank();
    }

    function test_SetLedger_RevertsOnZeroAndUnchanged() public {
        vm.startPrank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAddress.selector);
        dispatcher.setLedger(address(0));
        vm.expectRevert(FeeDispatcher.UnchangedValue.selector);
        dispatcher.setLedger(ledgerAddr);
        vm.stopPrank();
    }

    function test_EmergencyWithdraw_RevertsOnZeroAndFailedTransfer() public {
        vm.deal(address(dispatcher), 1 ether);
        FDRejectEther bad = new FDRejectEther();
        vm.startPrank(owner);
        vm.expectRevert(FeeDispatcher.ZeroAmount.selector);
        dispatcher.emergencyWithdraw(payable(alice), 0);
        vm.expectRevert(FeeDispatcher.TransferFailed.selector);
        dispatcher.emergencyWithdraw(payable(address(bad)), 1 ether);
        vm.stopPrank();
    }

    function test_AddRecipient_RevertsWhenTooMany() public {
        vm.startPrank(owner);
        for (uint256 i = 0; i < 20; i++) {
            dispatcher.addRecipient(payable(address(uint160(0x1000 + i))), 1);
        }
        vm.expectRevert(FeeDispatcher.TooManyRecipients.selector);
        dispatcher.addRecipient(payable(address(uint160(0x2000))), 1);
        vm.stopPrank();
    }
}

contract FDRejectEther {
    receive() external payable {
        revert("no");
    }
}
