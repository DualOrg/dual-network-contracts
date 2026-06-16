// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingV1} from "../src/legacy/StakingV1.sol";
import {Staking} from "../src/StakingFinal.sol";

/// @notice Validates that upgrading the deployed v1 `Staking` implementation to
///         `Staking` preserves all live state, seeds `committedRewards`
///         correctly, and wires up the ERC20Permit domain that v1 lacked.
///
///         The local simulation deliberately builds NON-ZERO reward state
///         (stake → notify → claim) so the cumulative→outstanding migration math
///         is actually exercised — the live chain is currently all zeros.
contract StakingFinalTest is Test {
    StakingV1 v1; // proxy, typed as v1 before the upgrade

    address owner = makeAddr("owner");
    address dispatcher = makeAddr("dispatcher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant REWARDS_DURATION = 7 days;

    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        StakingV1 impl = new StakingV1();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(StakingV1.initialize, (owner, dispatcher, REWARDS_DURATION)));
        v1 = StakingV1(payable(address(proxy)));
    }

    /// @dev Drive realistic v1 state: two stakers, a fee stream, partial elapse, a claim.
    function _buildNonZeroV1State() internal {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.prank(alice);
        v1.stake{value: 100 ether}();
        vm.prank(bob);
        v1.stake{value: 50 ether}();

        // Fees arrive from the dispatcher → starts a reward stream.
        vm.deal(dispatcher, 70 ether);
        vm.prank(dispatcher);
        (bool ok,) = address(v1).call{value: 70 ether}("");
        require(ok, "fee transfer failed");

        // Halfway through the period, alice claims → bumps totalRewardsClaimed.
        vm.warp(block.timestamp + REWARDS_DURATION / 2);
        vm.prank(alice);
        v1.claimRewards();

        // Sanity: we actually have non-zero cumulative counters to migrate.
        assertGt(v1.totalFeesDispatched(), 0, "precondition: dispatched > 0");
        assertGt(v1.totalRewardsClaimed(), 0, "precondition: claimed > 0");
    }

    function _upgrade() internal returns (Staking s) {
        Staking newImpl = new Staking();
        vm.prank(owner);
        v1.upgradeToAndCall(address(newImpl), abi.encodeCall(Staking.reinitializePermit, ()));
        s = Staking(payable(address(v1)));
    }

    // ── migration correctness ──────────────────────────────────────────────────

    function test_Upgrade_PreservesStateAndSeedsCommittedRewards() public {
        _buildNonZeroV1State();

        // Snapshot v1 state.
        uint256 dispatched = v1.totalFeesDispatched();
        uint256 claimed = v1.totalRewardsClaimed();
        uint256 totalStaked = v1.totalStaked();
        uint256 pending = v1.pendingRewards();
        uint256 rate = v1.rewardRate();
        uint256 finish = v1.periodFinish();
        uint256 rps = v1.rewardPerTokenStored();
        uint256 supply = v1.totalSupply();
        uint256 aliceBal = v1.balanceOf(alice);
        uint256 bobBal = v1.balanceOf(bob);
        uint256 alicePreview = v1.previewRewards(alice);
        uint256 bobPreview = v1.previewRewards(bob);

        Staking s = _upgrade();

        // Renamed slots keep their exact values.
        assertEq(s.lifetimeRewardsReceived(), dispatched + pending, "slot4 re-based to gross received (net + parked)");
        assertEq(s.lifetimeRewardsClaimed(), claimed, "slot5 value preserved");
        // New field seeded to live-outstanding.
        assertEq(s.committedRewards(), dispatched - claimed, "committedRewards seeded");

        // Everything else identical.
        assertEq(s.totalStaked(), totalStaked, "totalStaked");
        assertEq(s.pendingRewards(), pending, "pendingRewards");
        assertEq(s.rewardRate(), rate, "rewardRate");
        assertEq(s.periodFinish(), finish, "periodFinish");
        assertEq(s.rewardPerTokenStored(), rps, "rewardPerTokenStored");
        assertEq(s.totalSupply(), supply, "totalSupply");
        assertEq(s.feeDispatcher(), dispatcher, "feeDispatcher");
        assertEq(s.rewardsDuration(), REWARDS_DURATION, "rewardsDuration");
        assertEq(s.balanceOf(alice), aliceBal, "alice balance");
        assertEq(s.balanceOf(bob), bobBal, "bob balance");

        // The key staker-facing invariant: claimable rewards do not change.
        assertEq(s.previewRewards(alice), alicePreview, "alice preview unchanged");
        assertEq(s.previewRewards(bob), bobPreview, "bob preview unchanged");
    }

    /// @dev After the upgrade, stakers can still claim and the contract stays solvent.
    function test_Upgrade_ClaimStillWorksAndStaysSolvent() public {
        _buildNonZeroV1State();
        Staking s = _upgrade();

        vm.warp(block.timestamp + REWARDS_DURATION); // finish the stream

        uint256 alicePreview = s.previewRewards(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 claimed = s.claimRewards();
        assertEq(claimed, alicePreview, "claimed matches preview");
        assertEq(alice.balance - before, claimed, "DUAL received");

        // Solvency: balance covers principal + remaining committed + pending.
        uint256 reserved = s.totalSupply() + s.committedRewards() + s.pendingRewards();
        assertGe(address(s).balance, reserved, "solvent after claim");

        // bob can exit fully AND receives principal + his (freshly-streamed) rewards.
        uint256 bobShares = s.balanceOf(bob);
        uint256 bobRewards = s.previewRewards(bob);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        (uint256 outStaked, uint256 outRewards) = s.exit();
        assertEq(s.balanceOf(bob), 0, "bob fully exited");
        assertEq(outStaked, bobShares, "exit returns principal");
        assertEq(outRewards, bobRewards, "exit pays freshly-streamed rewards");
        assertEq(bob.balance - bobBefore, bobShares + bobRewards, "bob received principal + rewards");
    }

    /// @dev Regression (ChainSecurity #005 / #001) on the in-scope contract: a
    ///      stake while a stream is active must not re-notify it. Rate, periodFinish
    ///      and parked dust are left untouched, so the stream cannot be
    ///      permissionlessly stretched nor setRewardsDuration re-locked by a staker.
    function test_Stake_DoesNotRescheduleActiveStream() public {
        // Upgrade the (zero-state) proxy, then drive Staking directly.
        Staking s = _upgrade();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        s.stake{value: 1 ether}();

        // Fee that does not divide evenly → active stream plus a 1-wei parked dust.
        uint256 fee = 3 * REWARDS_DURATION + 1;
        vm.deal(dispatcher, fee);
        vm.prank(dispatcher);
        (bool ok,) = address(s).call{value: fee}("");
        assertTrue(ok);
        assertEq(s.rewardRate(), 3);
        assertEq(s.pendingRewards(), 1);

        vm.warp(block.timestamp + REWARDS_DURATION / 2);
        uint256 finishBefore = s.periodFinish();
        uint256 rateBefore = s.rewardRate();

        // Mid-stream stake: pendingRewards > 0 but a period is still active.
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        s.stake{value: 1 ether}();

        assertEq(s.periodFinish(), finishBefore, "stream must not be extended");
        assertEq(s.rewardRate(), rateBefore, "rate must not change");
        assertEq(s.pendingRewards(), 1, "dust must stay parked, not folded");
    }

    /// @dev Regression (ChainSecurity #003) on the in-scope contract: with a
    ///      zero-state migration (as on the live proxy) lifetimeRewardsReceived
    ///      seeds to 0 and must then count each external inflow exactly once, even
    ///      across a park-then-reschedule cycle.
    function test_LifetimeRewardsReceived_CountsInflowsOnce() public {
        Staking s = _upgrade(); // zero-state proxy → counter seeds to 0
        assertEq(s.lifetimeRewardsReceived(), 0, "seeds to zero on live-like state");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        s.stake{value: 1 ether}();

        uint256 fee1 = 7 ether;
        vm.deal(dispatcher, fee1);
        vm.prank(dispatcher);
        (bool ok1,) = address(s).call{value: fee1}("");
        assertTrue(ok1);

        vm.warp(block.timestamp + REWARDS_DURATION / 2);
        vm.prank(alice);
        s.exit();
        assertGt(s.pendingRewards(), 0, "remainder parked");

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        s.stake{value: 1 ether}(); // re-folds the parked remainder

        uint256 fee2 = 3 ether;
        vm.deal(dispatcher, fee2);
        vm.prank(dispatcher);
        (bool ok2,) = address(s).call{value: fee2}("");
        assertTrue(ok2);

        assertEq(s.lifetimeRewardsReceived(), fee1 + fee2, "counted each inflow once");
    }

    // ── permit wiring ───────────────────────────────────────────────────────────

    function test_Upgrade_InitialisesPermitDomain() public {
        _buildNonZeroV1State();
        Staking s = _upgrade();

        // Domain separator must match the intended ("Staked DUAL", "1") domain.
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("Staked DUAL")),
                keccak256(bytes("1")),
                block.chainid,
                address(s)
            )
        );
        assertEq(s.DOMAIN_SEPARATOR(), expected, "permit domain initialised to Staked DUAL");

        // A real permit signature must verify and set allowance.
        (address pOwner, uint256 pk) = makeAddrAndKey("permitOwner");
        address spender = makeAddr("spender");
        uint256 value = 5 ether;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = s.nonces(pOwner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, pOwner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", s.DOMAIN_SEPARATOR(), structHash));
        (uint8 vSig, bytes32 r, bytes32 sSig) = vm.sign(pk, digest);

        s.permit(pOwner, spender, value, deadline, vSig, r, sSig);
        assertEq(s.allowance(pOwner, spender), value, "permit set allowance");
        assertEq(s.nonces(pOwner), nonce + 1, "nonce consumed");
    }

    // ── reinitializer guards ─────────────────────────────────────────────────────

    function test_ReinitializePermit_OnlyOnce() public {
        Staking s = _upgrade();
        vm.prank(owner);
        vm.expectRevert(); // InvalidInitialization: reinitializer(2) already consumed
        s.reinitializePermit();
    }

    function test_ReinitializePermit_OnlyOwner() public {
        // Deploy a fresh v1 proxy and upgrade only the implementation (no init call),
        // so reinitializer(2) is still available, then prove non-owner can't call it.
        Staking newImpl = new Staking();
        vm.prank(owner);
        v1.upgradeToAndCall(address(newImpl), "");
        Staking s = Staking(payable(address(v1)));

        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        s.reinitializePermit();

        // Owner can.
        vm.prank(owner);
        s.reinitializePermit();
        assertTrue(s.DOMAIN_SEPARATOR() != bytes32(0));
    }

    // ── optional fork test against the real live proxy ───────────────────────────

    /// @dev Run with: DUAL_FORK_RPC=https://rpc.dual.network forge test --mt test_Fork
    function test_Fork_UpgradeLiveProxyPreservesState() public {
        string memory rpc = vm.envOr("DUAL_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            console2.log("DUAL_FORK_RPC not set - skipping live fork test");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address payable proxy = payable(0x69AD8a4eF0dDCD05A8b46053d04A5e20E7aDDcc1);
        StakingV1 live = StakingV1(proxy);

        address liveOwner = live.owner();
        address liveDispatcher = live.feeDispatcher();
        uint256 liveDuration = live.rewardsDuration();
        uint256 livePending = live.pendingRewards();
        uint256 liveDispatched = live.totalFeesDispatched();
        uint256 liveClaimed = live.totalRewardsClaimed();
        uint256 liveStaked = live.totalStaked();

        Staking newImpl = new Staking();
        vm.prank(liveOwner);
        live.upgradeToAndCall(address(newImpl), abi.encodeCall(Staking.reinitializePermit, ()));
        Staking s = Staking(proxy);

        assertEq(s.feeDispatcher(), liveDispatcher, "feeDispatcher preserved");
        assertEq(s.rewardsDuration(), liveDuration, "rewardsDuration preserved");
        assertEq(s.pendingRewards(), livePending, "pendingRewards preserved");
        assertEq(s.totalStaked(), liveStaked, "totalStaked preserved");
        assertEq(s.lifetimeRewardsReceived(), liveDispatched + livePending, "received re-based to gross (net + parked)");
        assertEq(s.lifetimeRewardsClaimed(), liveClaimed, "claimed preserved");
        assertEq(s.committedRewards(), liveDispatched - liveClaimed, "committedRewards seeded");
        assertTrue(s.DOMAIN_SEPARATOR() != bytes32(0), "permit domain initialised");
    }
}
