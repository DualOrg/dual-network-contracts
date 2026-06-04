// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vault} from "../src/Vault.sol";
import {FeeSource} from "../src/libraries/FeeSource.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VaultTest is Test {
    Vault vault;
    MockERC20 token;

    address owner = makeAddr("owner");
    address depositor = makeAddr("depositor");
    address feeDispatcher = makeAddr("feeDispatcher");
    address floatDepositor = makeAddr("floatDepositor");

    event OrgDeposited(address indexed depositor, bytes32 indexed orgId, address indexed token, uint256 amount);
    event FloatDeposited(address indexed depositor, uint256 amount);
    event FeeWithdrawal(address indexed to, uint256 amount, uint8 sourceType);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);

    function _deployVault(address _owner) internal returns (Vault) {
        Vault impl = new Vault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (_owner)));
        return Vault(payable(address(proxy)));
    }

    function setUp() public {
        vault = _deployVault(owner);
        token = new MockERC20();
    }

    function _setFeeDispatcher(address account) internal {
        vm.prank(owner);
        vault.setFeeDispatcher(account);
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_Initialize_SetsOwner() public view {
        assertEq(vault.owner(), owner);
    }

    function test_Initialize_RevertsOnZeroAddress() public {
        Vault impl = new Vault();
        vm.expectRevert(Vault.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(Vault.initialize, (address(0))));
    }

    function test_Initialize_GrantsAdminRole() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_Initialize_FeeDispatcherDefaultsToZero() public view {
        assertEq(vault.feeDispatcher(), address(0));
    }

    // ── deposit ──────────────────────────────────────────────────────────────

    function test_Deposit_TransfersTokens() public {
        token.mint(depositor, 100 ether);
        vm.startPrank(depositor);
        token.approve(address(vault), 100 ether);
        vault.deposit(address(token), keccak256("orgId"), 100 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function test_Deposit_EmitsOrgDeposited() public {
        bytes32 orgId = keccak256("org");
        token.mint(depositor, 1 ether);
        vm.startPrank(depositor);
        token.approve(address(vault), 1 ether);

        vm.expectEmit(true, true, true, true);
        emit OrgDeposited(depositor, orgId, address(token), 1 ether);
        vault.deposit(address(token), orgId, 1 ether);
        vm.stopPrank();
    }

    function test_Deposit_RevertsOnZeroToken() public {
        vm.expectRevert(Vault.InvalidToken.selector);
        vm.prank(depositor);
        vault.deposit(address(0), keccak256("orgId"), 1 ether);
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.expectRevert(Vault.ZeroAmount.selector);
        vm.prank(depositor);
        vault.deposit(address(token), keccak256("orgId"), 0);
    }

    function test_Deposit_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        token.mint(depositor, 1 ether);
        vm.startPrank(depositor);
        token.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.deposit(address(token), keccak256("orgId"), 1 ether);
        vm.stopPrank();
    }

    // ── depositDual ──────────────────────────────────────────────────────────

    function test_DepositDual_AcceptsETH() public {
        bytes32 orgId = keccak256("org");
        vm.deal(depositor, 1 ether);
        vm.prank(depositor);
        vault.depositDual{value: 1 ether}(orgId);

        assertEq(address(vault).balance, 1 ether);
    }

    function test_DepositDual_EmitsOrgDeposited() public {
        bytes32 orgId = keccak256("org");
        vm.deal(depositor, 1 ether);

        vm.expectEmit(true, true, true, true);
        emit OrgDeposited(depositor, orgId, vault.NATIVE_DUAL(), 1 ether);
        vm.prank(depositor);
        vault.depositDual{value: 1 ether}(orgId);
    }

    function test_DepositDual_RevertsOnZeroValue() public {
        vm.expectRevert(Vault.ZeroAmount.selector);
        vm.prank(depositor);
        vault.depositDual{value: 0}(keccak256("org"));
    }

    function test_DepositDual_RevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.deal(depositor, 1 ether);
        vm.expectRevert();
        vm.prank(depositor);
        vault.depositDual{value: 1 ether}(keccak256("org"));
    }

    // ── depositFloat ─────────────────────────────────────────────────────────

    function test_DepositFloat_Succeeds() public {
        vm.prank(owner);
        vault.grantFloatDepositorRole(floatDepositor);

        vm.deal(floatDepositor, 1 ether);
        vm.prank(floatDepositor);
        vault.depositFloat{value: 1 ether}();

        assertEq(address(vault).balance, 1 ether);
    }

    function test_DepositFloat_EmitsFloatDeposited() public {
        vm.prank(owner);
        vault.grantFloatDepositorRole(floatDepositor);

        vm.deal(floatDepositor, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit FloatDeposited(floatDepositor, 1 ether);
        vm.prank(floatDepositor);
        vault.depositFloat{value: 1 ether}();
    }

    function test_DepositFloat_RevertsWithoutRole() public {
        vm.deal(depositor, 1 ether);
        vm.expectRevert();
        vm.prank(depositor);
        vault.depositFloat{value: 1 ether}();
    }

    function test_DepositFloat_RevertsOnZeroValue() public {
        vm.prank(owner);
        vault.grantFloatDepositorRole(floatDepositor);

        vm.expectRevert(Vault.ZeroAmount.selector);
        vm.prank(floatDepositor);
        vault.depositFloat{value: 0}();
    }

    // ── withdraw ─────────────────────────────────────────────────────────────

    function test_Withdraw_TransfersERC20() public {
        token.mint(address(vault), 50 ether);
        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vault.withdraw(address(token), recipient, 50 ether);

        assertEq(token.balanceOf(recipient), 50 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_Withdraw_EmitsWithdrawn() public {
        token.mint(address(vault), 1 ether);
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(token), recipient, 1 ether);
        vm.prank(owner);
        vault.withdraw(address(token), recipient, 1 ether);
    }

    function test_Withdraw_RevertsOnlyOwner() public {
        vm.expectRevert();
        vault.withdraw(address(token), depositor, 1 ether);
    }

    function test_Withdraw_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.withdraw(address(token), address(0), 1 ether);
    }

    function test_Withdraw_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdraw(address(token), depositor, 0);
    }

    // ── withdrawDual ─────────────────────────────────────────────────────────

    function test_WithdrawDual_SendsETH() public {
        vm.deal(address(vault), 2 ether);
        address recipient = makeAddr("recipient");

        vm.prank(owner);
        vault.withdrawDual(recipient, 1 ether);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_WithdrawDual_RevertsOnInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdrawDual(owner, 1 ether);
    }

    function test_WithdrawDual_RevertsOnZeroAddress() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.withdrawDual(address(0), 1 ether);
    }

    function test_WithdrawDual_RevertsOnlyOwner() public {
        vm.deal(address(vault), 1 ether);
        vm.expectRevert();
        vault.withdrawDual(depositor, 1 ether);
    }

    // ── withdrawForFeeDistribution ───────────────────────────────────────────

    function test_WithdrawForFeeDistribution_UpdatesTotals() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        vm.prank(feeDispatcher);
        vault.withdrawForFeeDistribution(1 ether, FeeSource.BATCH);

        assertEq(vault.totalWithdrawnForFees(), 1 ether);
    }

    function test_WithdrawForFeeDistribution_SendsETHToSender() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        uint256 before = feeDispatcher.balance;
        vm.prank(feeDispatcher);
        vault.withdrawForFeeDistribution(1 ether, FeeSource.BATCH);

        assertEq(feeDispatcher.balance - before, 1 ether);
    }

    function test_WithdrawForFeeDistribution_AcceptsLedgerSource() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        vm.prank(feeDispatcher);
        bool ok = vault.withdrawForFeeDistribution(0.5 ether, FeeSource.LEDGER);
        assertTrue(ok);
    }

    function test_WithdrawForFeeDistribution_RevertsFromNonFeeDispatcher() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        vm.prank(depositor);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.withdrawForFeeDistribution(1 ether, FeeSource.BATCH);
    }

    function test_WithdrawForFeeDistribution_RevertsOnInvalidSourceType() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        vm.prank(feeDispatcher);
        vm.expectRevert(Vault.InvalidSourceType.selector);
        vault.withdrawForFeeDistribution(1 ether, 99);
    }

    function test_WithdrawForFeeDistribution_RevertsWhenPaused() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);
        vm.prank(owner);
        vault.pause();

        vm.prank(feeDispatcher);
        vm.expectRevert();
        vault.withdrawForFeeDistribution(1 ether, FeeSource.BATCH);
    }

    function test_WithdrawForFeeDistribution_RevertsOnInsufficientBalance() public {
        _setFeeDispatcher(feeDispatcher);

        vm.prank(feeDispatcher);
        vm.expectRevert(Vault.InsufficientBalance.selector);
        vault.withdrawForFeeDistribution(1 ether, FeeSource.BATCH);
    }

    function test_WithdrawForFeeDistribution_RevertsOnZeroAmount() public {
        vm.deal(address(vault), 5 ether);
        _setFeeDispatcher(feeDispatcher);

        vm.prank(feeDispatcher);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdrawForFeeDistribution(0, FeeSource.BATCH);
    }

    // ── setFeeDispatcher ─────────────────────────────────────────────────────

    function test_SetFeeDispatcher_Succeeds() public {
        vm.expectEmit(true, true, false, false);
        emit FeeDispatcherUpdated(address(0), feeDispatcher);
        vm.prank(owner);
        vault.setFeeDispatcher(feeDispatcher);

        assertEq(vault.feeDispatcher(), feeDispatcher);
    }

    function test_SetFeeDispatcher_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.setFeeDispatcher(address(0));
    }

    function test_SetFeeDispatcher_RevertsOnSameValue() public {
        _setFeeDispatcher(feeDispatcher);

        vm.prank(owner);
        vm.expectRevert(Vault.UnchangedValue.selector);
        vault.setFeeDispatcher(feeDispatcher);
    }

    function test_SetFeeDispatcher_RevertsOnlyOwner() public {
        vm.expectRevert();
        vm.prank(depositor);
        vault.setFeeDispatcher(feeDispatcher);
    }

    // ── role management ──────────────────────────────────────────────────────

    function test_GrantFloatDepositorRole_Succeeds() public {
        vm.prank(owner);
        vault.grantFloatDepositorRole(floatDepositor);

        assertTrue(vault.hasRole(vault.FLOAT_DEPOSITOR_ROLE(), floatDepositor));
    }

    function test_GrantFloatDepositorRole_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAddress.selector);
        vault.grantFloatDepositorRole(address(0));
    }

    function test_RevokeFloatDepositorRole_Succeeds() public {
        vm.prank(owner);
        vault.grantFloatDepositorRole(floatDepositor);

        vm.prank(owner);
        vault.revokeFloatDepositorRole(floatDepositor);

        assertFalse(vault.hasRole(vault.FLOAT_DEPOSITOR_ROLE(), floatDepositor));
    }

    // ── pause / unpause ──────────────────────────────────────────────────────

    function test_Pause_OnlyOwner() public {
        vm.prank(owner);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(depositor);
        vault.pause();
    }

    function test_Unpause_Succeeds() public {
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    // ── coverage: revert/edge paths ───────────────────────────────────────────

    function test_WithdrawDual_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdrawDual(owner, 0);
    }

    function test_WithdrawForFeeDistribution_RevertsWhenDispatcherRejects() public {
        VaultRejectingDispatcher d = new VaultRejectingDispatcher(vault);
        vm.prank(owner);
        vault.setFeeDispatcher(address(d));

        vm.deal(address(this), 1 ether);
        vault.depositDual{value: 1 ether}(keccak256("org"));

        vm.expectRevert(Vault.TransferFailed.selector);
        d.pull(1 ether);
    }
}

contract VaultRejectingDispatcher {
    Vault internal vault;

    constructor(Vault _v) {
        vault = _v;
    }

    function pull(uint256 amount) external {
        vault.withdrawForFeeDistribution(amount, FeeSource.LEDGER);
    }

    receive() external payable {
        revert("no");
    }
}
