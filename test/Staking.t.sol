// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Staking} from "../src/Staking.sol";

/// @dev A holder that rejects all incoming native transfers, used to drive the
///      `TransferFailed` paths on unstake, claim, and exit.
contract RejectEther {
    Staking public immutable staking;

    constructor(Staking _staking) {
        staking = _staking;
    }

    function doStake() external payable {
        staking.stake{value: msg.value}();
    }

    function doUnstake(uint256 amount) external {
        staking.unstake(amount);
    }

    function doClaim() external {
        staking.claimRewards();
    }

    function doExit() external {
        staking.exit();
    }

    receive() external payable {
        revert("nope");
    }
}

contract StakingTest is Test {
    Staking staking;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address dispatcher = makeAddr("dispatcher");

    uint256 constant REWARDS_DURATION = 7 days;

    event Staked(address indexed user, uint256 dualAmount, uint256 xDualMinted);
    event Unstaked(address indexed user, uint256 dualAmount, uint256 xDualBurned);
    event FeesReceived(address indexed from, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsParked(uint256 amount, uint256 totalPending);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);

    function _deployStaking(address _owner, address _dispatcher, uint256 _duration) internal returns (Staking) {
        Staking impl = new Staking();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Staking.initialize, (_owner, _dispatcher, _duration)));
        return Staking(payable(address(proxy)));
    }

    function setUp() public {
        staking = _deployStaking(owner, dispatcher, REWARDS_DURATION);
    }

    // ── initialize ───────────────────────────────────────────────────────────

    function test_Initialize_SetsNameAndSymbol() public view {
        assertEq(staking.name(), "Staked DUAL");
        assertEq(staking.symbol(), "xDUAL");
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(staking.owner(), owner);
    }

    function test_Initialize_SetsFeeDispatcher() public view {
        assertEq(staking.feeDispatcher(), dispatcher);
    }

    function test_Initialize_SetsRewardsDuration() public view {
        assertEq(staking.rewardsDuration(), REWARDS_DURATION);
    }

    function test_Initialize_RevertsOnZeroOwner() public {
        Staking impl = new Staking();
        vm.expectRevert(Staking.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(Staking.initialize, (address(0), dispatcher, REWARDS_DURATION)));
    }

    function test_Initialize_RevertsOnZeroFeeDispatcher() public {
        Staking impl = new Staking();
        vm.expectRevert(Staking.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(Staking.initialize, (owner, address(0), REWARDS_DURATION)));
    }

    function test_Initialize_RevertsOnDurationTooShort() public {
        Staking impl = new Staking();
        vm.expectRevert(Staking.InvalidDuration.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(Staking.initialize, (owner, dispatcher, 30 minutes)));
    }

    function test_Initialize_RevertsOnDurationTooLong() public {
        Staking impl = new Staking();
        vm.expectRevert(Staking.InvalidDuration.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(Staking.initialize, (owner, dispatcher, 31 days)));
    }

    function test_Initialize_EmitsFeeDispatcherUpdated() public {
        vm.expectEmit(true, true, false, false);
        emit FeeDispatcherUpdated(address(0), dispatcher);
        _deployStaking(owner, dispatcher, REWARDS_DURATION);
    }

    // ── stake ────────────────────────────────────────────────────────────────

    function test_Stake_MintsXDUAL() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        assertEq(staking.balanceOf(alice), 1 ether);
    }

    function test_Stake_UpdatesTotalSupply() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        staking.stake{value: 2 ether}();

        assertEq(staking.totalSupply(), 2 ether);
    }

    function test_Stake_AutoDelegates() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        assertEq(staking.delegates(alice), alice);
    }

    function test_Transfer_AutoDelegatesRecipientAndActivatesVotes() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        // Bob has never staked nor delegated.
        assertEq(staking.delegates(bob), address(0));
        assertEq(staking.getVotes(bob), 0);

        vm.prank(alice);
        staking.transfer(bob, 0.4 ether);

        // Receiving xDUAL auto-self-delegates Bob and makes the weight live.
        assertEq(staking.delegates(bob), bob);
        assertEq(staking.getVotes(bob), 0.4 ether);
        assertEq(staking.getVotes(alice), 0.6 ether);

        // Total active voting supply is preserved (nothing routed to address(0)).
        assertEq(staking.getVotes(alice) + staking.getVotes(bob), staking.totalSupply());
    }

    function test_Transfer_DoesNotOverrideExistingDelegation() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        // Bob explicitly delegates to alice before ever holding tokens.
        vm.prank(bob);
        staking.delegate(alice);
        assertEq(staking.delegates(bob), alice);

        vm.prank(alice);
        staking.transfer(bob, 0.4 ether);

        // Auto-delegation must not clobber a deliberate delegation choice.
        assertEq(staking.delegates(bob), alice);
        assertEq(staking.getVotes(alice), 1 ether); // alice holds 0.6, delegated 0.4 from bob
        assertEq(staking.getVotes(bob), 0);
    }

    function test_Stake_RevertsOnZeroValue() public {
        vm.expectRevert(Staking.ZeroAmount.selector);
        vm.prank(alice);
        staking.stake{value: 0}();
    }

    function test_Stake_EmitsEvent() public {
        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Staked(alice, 1 ether, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();
    }

    function test_Stake_RevertsWhenPaused() public {
        vm.prank(owner);
        staking.pause();

        vm.deal(alice, 1 ether);
        vm.expectRevert();
        vm.prank(alice);
        staking.stake{value: 1 ether}();
    }

    function test_Stake_FoldsPendingRewards() public {
        // Park rewards before any staker
        uint256 rewards = 0.5 ether;
        vm.deal(dispatcher, rewards);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: rewards}("");
        assertTrue(ok);
        assertEq(staking.pendingRewards(), rewards);

        // Alice stakes — pending rewards should be folded into a stream
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        assertEq(staking.pendingRewards(), rewards % REWARDS_DURATION);
        assertGt(staking.rewardRate(), 0);
    }

    function test_Stake_KeepsTinyPendingRewardDust() public {
        uint256 dust = REWARDS_DURATION - 1;

        vm.deal(dispatcher, dust);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: dust}("");
        assertTrue(ok);
        assertEq(staking.pendingRewards(), dust);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        assertEq(staking.pendingRewards(), dust);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.committedRewards(), 0);
        assertEq(address(staking).balance, staking.totalSupply() + staking.pendingRewards());
    }

    // ── unstake ──────────────────────────────────────────────────────────────

    function test_Unstake_BurnsXDUALAndReturnsETH() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        staking.unstake(1 ether);

        assertEq(staking.balanceOf(alice), 0);
        assertEq(alice.balance - balBefore, 1 ether);
        assertEq(staking.totalSupply(), 0);
    }

    function test_Unstake_RevertsOnZeroAmount() public {
        vm.expectRevert(Staking.ZeroAmount.selector);
        vm.prank(alice);
        staking.unstake(0);
    }

    function test_Unstake_RevertsOnInsufficientBalance() public {
        vm.expectRevert(Staking.InsufficientBalance.selector);
        vm.prank(alice);
        staking.unstake(1 ether);
    }

    function test_Unstake_EmitsEvent() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.expectEmit(true, false, false, true);
        emit Unstaked(alice, 1 ether, 1 ether);
        vm.prank(alice);
        staking.unstake(1 ether);
    }

    function test_Unstake_LastStakerParksUnstreamedRewards() public {
        uint256 rate = 7 gwei;
        uint256 fees = rate * REWARDS_DURATION;

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, fees);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: fees}("");
        assertTrue(ok);

        vm.warp(block.timestamp + 1 days);

        uint256 accrued = rate * 1 days;
        uint256 leftover = rate * (REWARDS_DURATION - 1 days);

        vm.prank(alice);
        staking.unstake(1 ether);

        assertEq(staking.totalSupply(), 0);
        assertEq(staking.pendingRewards(), leftover);
        assertEq(staking.committedRewards(), accrued);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.periodFinish(), block.timestamp);
        assertEq(staking.previewRewards(alice), accrued);
        assertEq(
            address(staking).balance, staking.totalSupply() + staking.committedRewards() + staking.pendingRewards()
        );
    }

    // ── claimRewards ─────────────────────────────────────────────────────────

    function test_ClaimRewards_RevertsOnNothingToClaim() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.expectRevert(Staking.NothingToClaim.selector);
        vm.prank(alice);
        staking.claimRewards();
    }

    function test_ClaimRewards_AfterStreamEnds() public {
        // Alice stakes
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        // Dispatcher sends fees
        uint256 fees = 0.1 ether;
        vm.deal(dispatcher, fees);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: fees}("");
        assertTrue(ok);

        // Advance past end of period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        uint256 preview = staking.previewRewards(alice);
        assertGt(preview, 0);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        staking.claimRewards();

        assertGt(alice.balance - balBefore, 0);
    }

    function test_ClaimRewards_EmitsEvent() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        vm.expectEmit(true, false, false, false);
        emit RewardsClaimed(alice, 0);
        vm.prank(alice);
        staking.claimRewards();
    }

    function test_ClaimRewards_TwoStakers_ProportionalSplit() public {
        // Alice and Bob stake equal amounts
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        staking.stake{value: 1 ether}();

        // Dispatcher sends fees
        vm.deal(dispatcher, 0.2 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.2 ether}("");
        assertTrue(ok);

        // Advance past end of period
        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        uint256 aliceRewards = staking.previewRewards(alice);
        uint256 bobRewards = staking.previewRewards(bob);

        // Equal stakes → equal rewards (within rounding)
        assertApproxEqAbs(aliceRewards, bobRewards, 1);
    }

    // ── receive (fee dispatch) ────────────────────────────────────────────────

    function test_Receive_RevertsFromNonDispatcher() public {
        vm.deal(alice, 1 ether);
        vm.expectRevert(Staking.Unauthorized.selector);
        vm.prank(alice);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        (ok); // suppress unused variable warning
    }

    function test_Receive_ParksRewardsWhenNoStakers() public {
        vm.deal(dispatcher, 1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(staking.pendingRewards(), 1 ether);
        assertEq(staking.rewardRate(), 0);
    }

    function test_Receive_StartsStreamWhenStakersExist() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        assertGt(staking.rewardRate(), 0);
        assertGt(staking.periodFinish(), block.timestamp);
    }

    function test_Receive_EmitsFeesReceived() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.expectEmit(true, false, false, true);
        emit FeesReceived(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);
    }

    // ── setFeeDispatcher ─────────────────────────────────────────────────────

    function test_SetFeeDispatcher_UpdatesAddress() public {
        address newDispatcher = makeAddr("newDispatcher");
        vm.prank(owner);
        staking.setFeeDispatcher(newDispatcher);

        assertEq(staking.feeDispatcher(), newDispatcher);
    }

    function test_SetFeeDispatcher_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Staking.InvalidAddress.selector);
        staking.setFeeDispatcher(address(0));
    }

    function test_SetFeeDispatcher_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(Staking.UnchangedValue.selector);
        staking.setFeeDispatcher(dispatcher);
    }

    function test_SetFeeDispatcher_RevertsFromNonOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        staking.setFeeDispatcher(makeAddr("x"));
    }

    // ── setRewardsDuration ────────────────────────────────────────────────────

    function test_SetRewardsDuration_OnlyOwner() public {
        vm.prank(owner);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days);
    }

    function test_SetRewardsDuration_RevertsWhenPeriodActive() public {
        // Start a period
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        // Should revert since period is active
        vm.prank(owner);
        vm.expectRevert(Staking.InvalidDuration.selector);
        staking.setRewardsDuration(14 days);
    }

    function test_SetRewardsDuration_RevertsOnSameValue() public {
        vm.prank(owner);
        vm.expectRevert(Staking.UnchangedValue.selector);
        staking.setRewardsDuration(REWARDS_DURATION);
    }

    // ── previewRewards ────────────────────────────────────────────────────────

    function test_PreviewRewards_ZeroBeforeStaking() public view {
        assertEq(staking.previewRewards(alice), 0);
    }

    function test_PreviewRewards_GrowsOverTime() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        uint256 preview1 = staking.previewRewards(alice);

        vm.warp(block.timestamp + 1 days);
        uint256 preview2 = staking.previewRewards(alice);

        assertGt(preview2, preview1);
    }

    // ── exit ─────────────────────────────────────────────────────────────────

    function test_Exit_ClaimsRewardsAndUnstakes() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        (uint256 principal, uint256 rewards) = staking.exit();

        assertEq(principal, 1 ether);
        assertGt(rewards, 0);
        assertEq(staking.balanceOf(alice), 0);
        assertEq(alice.balance - balBefore, principal + rewards);
        assertEq(staking.totalSupply(), 0);
    }

    function test_Exit_RevertsWhenNothingStakedAndNoRewards() public {
        vm.expectRevert(Staking.NothingToClaim.selector);
        vm.prank(alice);
        staking.exit();
    }

    function test_Exit_WorksWithNoRewards() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        // No fees dispatched — exit should still return principal
        uint256 balBefore = alice.balance;
        vm.prank(alice);
        (uint256 principal, uint256 rewards) = staking.exit();

        assertEq(principal, 1 ether);
        assertEq(rewards, 0);
        assertEq(alice.balance - balBefore, 1 ether);
    }

    function test_Exit_WorksWhenPaused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.prank(owner);
        staking.pause();

        // exit (like unstake) should work even when paused
        vm.prank(alice);
        (uint256 principal,) = staking.exit();
        assertEq(principal, 1 ether);
    }

    function test_Exit_LastStakerParksUnstreamedRewards() public {
        uint256 rate = 7 gwei;
        uint256 fees = rate * REWARDS_DURATION;

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, fees);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: fees}("");
        assertTrue(ok);

        vm.warp(block.timestamp + 1 days);

        uint256 accrued = rate * 1 days;
        uint256 leftover = rate * (REWARDS_DURATION - 1 days);
        uint256 balBefore = alice.balance;

        vm.prank(alice);
        (uint256 principal, uint256 rewards) = staking.exit();

        assertEq(principal, 1 ether);
        assertEq(rewards, accrued);
        assertEq(alice.balance - balBefore, principal + rewards);
        assertEq(staking.totalSupply(), 0);
        assertEq(staking.pendingRewards(), leftover);
        assertEq(staking.committedRewards(), 0);
        assertEq(staking.lifetimeRewardsClaimed(), accrued);
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.periodFinish(), block.timestamp);
        assertEq(address(staking).balance, staking.pendingRewards());
    }

    function test_Exit_EmitsUnstakedAndRewardsClaimed() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.deal(dispatcher, 0.1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 0.1 ether}("");
        assertTrue(ok);

        vm.warp(block.timestamp + REWARDS_DURATION + 1);

        vm.expectEmit(true, false, false, false);
        emit Unstaked(alice, 0, 0);
        vm.expectEmit(true, false, false, false);
        emit RewardsClaimed(alice, 0);
        vm.prank(alice);
        staking.exit();
    }

    // ── pause / unpause ───────────────────────────────────────────────────────

    function test_Pause_OnlyOwner() public {
        vm.prank(owner);
        staking.pause();
        assertTrue(staking.paused());
    }

    function test_Unpause_Succeeds() public {
        vm.prank(owner);
        staking.pause();
        vm.prank(owner);
        staking.unpause();
        assertFalse(staking.paused());
    }

    function test_Unstake_AllowedWhenPaused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.prank(owner);
        staking.pause();

        // Unstake is allowed even when paused (deliberate design)
        vm.prank(alice);
        staking.unstake(1 ether);
        assertEq(staking.balanceOf(alice), 0);
    }

    /// @dev Fees arriving while paused are parked, not streamed; `unpause` schedules them.
    function test_Pause_ParksFeesAndUnpauseSchedules() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        vm.prank(owner);
        staking.pause();

        uint256 fees = 7 * REWARDS_DURATION; // exact-rate amount, no dust
        vm.deal(dispatcher, fees);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: fees}("");
        assertTrue(ok);

        // Parked, not streamed.
        assertEq(staking.pendingRewards(), fees, "fees parked while paused");
        assertEq(staking.rewardRate(), 0, "no stream started while paused");
        assertEq(staking.periodFinish(), 0, "no period while paused");
        assertEq(staking.previewRewards(alice), 0, "nothing accruing while paused");

        // Unpause schedules the parked rewards into a stream.
        vm.prank(owner);
        staking.unpause();

        assertEq(staking.pendingRewards(), 0, "parked rewards scheduled on unpause");
        assertEq(staking.rewardRate(), 7, "stream started on unpause");
        assertEq(staking.periodFinish(), block.timestamp + REWARDS_DURATION, "period set on unpause");

        // After the full period alice has earned the parked fees.
        vm.warp(block.timestamp + REWARDS_DURATION);
        assertEq(staking.previewRewards(alice), fees, "alice earns the parked fees post-unpause");
    }

    // ── regression: _notifyReward accounting (M-1 / Low-2) ────────────────────

    /// @dev A tiny top-up during an active high-rate period drives the recomputed
    ///      rate below the old leftover (scheduled < leftover). The released
    ///      shortfall must be parked exactly once; the old code double-parked it,
    ///      inflating pendingRewards above the contract's real balance.
    function test_NotifyReward_ShortfallDoesNotInflatePending() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        // Exact rate of 3 wei/sec over the full duration.
        uint256 f1 = 3 * REWARDS_DURATION;
        vm.deal(dispatcher, f1);
        vm.prank(dispatcher);
        (bool ok1,) = address(staking).call{value: f1}("");
        assertTrue(ok1);
        assertEq(staking.rewardRate(), 3);

        // Advance 1s, then notify a 1-wei top-up: leftover = 3*(D-1),
        // newRate = floor((1 + 3*(D-1))/D) = 2, scheduled = 2*D < leftover.
        vm.warp(block.timestamp + 1);
        vm.deal(dispatcher, 1);
        vm.prank(dispatcher);
        (bool ok2,) = address(staking).call{value: 1}("");
        assertTrue(ok2);
        assertEq(staking.rewardRate(), 2);

        // Invariant: reserved liabilities never exceed the actual balance, and
        // here the balance is fully reserved (no phantom surplus, no shortage).
        uint256 reserved = staking.totalSupply() + staking.committedRewards() + staking.pendingRewards();
        assertEq(reserved, address(staking).balance);

        // Parked amount is exactly the rounding dust (D-2 wei), not dust+shortfall.
        assertEq(staking.pendingRewards(), REWARDS_DURATION - 2);
    }

    /// @dev End-to-end of the reported PoC: with the double-park bug, the inflated
    ///      pendingRewards later makes a fresh stake revert RewardRateTooHigh even
    ///      though principal/rewards were paid correctly. Must succeed post-fix.
    function test_NotifyReward_ShortfallDoesNotBrickFutureStake() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        uint256 f1 = 3 * REWARDS_DURATION;
        vm.deal(dispatcher, f1);
        vm.prank(dispatcher);
        (bool ok1,) = address(staking).call{value: f1}("");
        assertTrue(ok1);

        vm.warp(block.timestamp + 1);
        vm.deal(dispatcher, 1);
        vm.prank(dispatcher);
        (bool ok2,) = address(staking).call{value: 1}("");
        assertTrue(ok2);

        // Last staker exits; remaining stream is parked back into pendingRewards.
        vm.prank(alice);
        staking.unstake(1 ether);
        assertEq(staking.totalSupply(), 0);

        // A new staker folds the parked rewards back into a stream. This is the
        // call that reverted RewardRateTooHigh under the bug.
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        staking.stake{value: 1 ether}();
        assertEq(staking.balanceOf(bob), 1 ether);

        uint256 reserved = staking.totalSupply() + staking.committedRewards() + staking.pendingRewards();
        assertLe(reserved, address(staking).balance);
    }

    /// @dev When amount + leftover < rewardsDuration nothing can be scheduled.
    ///      The funds are fully parked and the period must stay CLOSED, otherwise
    ///      a zero-rate "active" window falsely blocks setRewardsDuration().
    function test_NotifyReward_ZeroRateDoesNotBlockSetRewardsDuration() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        staking.stake{value: 1 ether}();

        uint256 dust = REWARDS_DURATION - 1;
        vm.deal(dispatcher, dust);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: dust}("");
        assertTrue(ok);

        assertEq(staking.rewardRate(), 0);
        assertEq(staking.periodFinish(), block.timestamp); // period closed, not extended
        assertEq(staking.pendingRewards(), dust);

        // No active period => owner can adjust the duration.
        vm.prank(owner);
        staking.setRewardsDuration(14 days);
        assertEq(staking.rewardsDuration(), 14 days);
    }

    // ── regression: EIP-712 domain (Low-1) ────────────────────────────────────

    function test_Initialize_SetsEIP712Domain() public view {
        (, string memory name, string memory version,,,,) = staking.eip712Domain();
        assertEq(name, "Staked DUAL");
        assertEq(version, "1");
    }

    // ── coverage: native-send failure paths (TransferFailed) ─────────────────

    function test_Unstake_RevertsWhenRecipientRejectsEth() public {
        RejectEther r = new RejectEther(staking);
        vm.deal(address(r), 1 ether);
        r.doStake{value: 1 ether}();

        vm.expectRevert(Staking.TransferFailed.selector);
        r.doUnstake(1 ether);
    }

    function test_ClaimRewards_RevertsWhenRecipientRejectsEth() public {
        RejectEther r = new RejectEther(staking);
        vm.deal(address(r), 1 ether);
        r.doStake{value: 1 ether}();

        // Stream some fees so there is something to claim.
        vm.deal(dispatcher, 1 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        assertTrue(ok);
        vm.warp(block.timestamp + REWARDS_DURATION); // fully streamed

        assertGt(staking.previewRewards(address(r)), 0);
        vm.expectRevert(Staking.TransferFailed.selector);
        r.doClaim();
    }

    function test_Exit_RevertsWhenRecipientRejectsEth() public {
        RejectEther r = new RejectEther(staking);
        vm.deal(address(r), 1 ether);
        r.doStake{value: 1 ether}();

        vm.expectRevert(Staking.TransferFailed.selector);
        r.doExit();
    }

    // ── coverage: view descriptors ───────────────────────────────────────────
    // NOTE: the `RewardRateTooHigh` guard in `_notifyReward` (line ~385) is
    // intentionally unreachable under correct accounting — `scheduled` can only
    // exceed `_availableForRewards() + leftover` if `pendingRewards` outruns the
    // real balance, the exact corruption `invariant_solvent` proves never occurs.
    // It is left as defense-in-depth, so that branch stays uncovered by design.

    function test_ClockMode_IsTimestamp() public view {
        assertEq(staking.CLOCK_MODE(), "mode=timestamp");
        assertEq(staking.clock(), uint48(block.timestamp));
    }

    /// @dev permit() works against the configured EIP-712 domain (proves the
    ///      domain is non-empty and the ERC20Permit wiring is live).
    function test_Permit_SetsAllowance() public {
        uint256 ownerKey = 0xA11CE;
        address permitOwner = vm.addr(ownerKey);
        uint256 value = 5 ether;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                permitOwner,
                bob,
                value,
                staking.nonces(permitOwner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", staking.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        staking.permit(permitOwner, bob, value, deadline, v, r, s);

        assertEq(staking.allowance(permitOwner, bob), value);
        assertEq(staking.nonces(permitOwner), 1);
    }
}
