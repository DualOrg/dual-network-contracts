// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Staking} from "../src/Staking.sol";

/// @dev Drives randomized sequences of every state-changing entrypoint against a
///      single Staking proxy. The handler is BOTH the owner and the feeDispatcher
///      so it can exercise owner-only paths (addBonus, pause, setRewardsDuration)
///      and the receive() fee path. A short reward duration
///      plus a "tiny fees" action deliberately stress the sub-duration rounding
///      regime where the original double-park bug (M-1) lived.
contract StakingHandler is Test {
    Staking public immutable staking;

    uint256 public constant ACTOR_COUNT = 4;
    address[] public actors;

    // Ghost accounting of native flows, cross-checked by invariant_conservation.
    uint256 public ghost_principalIn; // native staked
    uint256 public ghost_principalOut; // native returned as principal
    uint256 public ghost_rewardsIn; // native delivered as fees + bonus
    uint256 public ghost_rewardsOut; // native paid out as rewards

    address internal currentActor;

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, ACTOR_COUNT - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(Staking _staking) {
        staking = _staking;
        for (uint256 i; i < ACTOR_COUNT; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
        }
    }

    receive() external payable {}

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ── staker actions ────────────────────────────────────────────────────────

    function stake(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        amount = bound(amount, 1, 100 ether);
        vm.deal(currentActor, currentActor.balance + amount);
        try staking.stake{value: amount}() {
            ghost_principalIn += amount;
        } catch {}
    }

    function unstake(uint256 actorSeed, uint256 amount) public useActor(actorSeed) {
        uint256 bal = staking.balanceOf(currentActor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try staking.unstake(amount) {
            ghost_principalOut += amount;
        } catch {}
    }

    function claim(uint256 actorSeed) public useActor(actorSeed) {
        try staking.claimRewards() returns (uint256 amount) {
            ghost_rewardsOut += amount;
        } catch {}
    }

    function exit(uint256 actorSeed) public useActor(actorSeed) {
        try staking.exit() returns (uint256 staked, uint256 rewards) {
            ghost_principalOut += staked;
            ghost_rewardsOut += rewards;
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public useActor(fromSeed) {
        address to = actors[bound(toSeed, 0, ACTOR_COUNT - 1)];
        uint256 bal = staking.balanceOf(currentActor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        try staking.transfer(to, amount) {} catch {}
    }

    /// @dev Delegate to another actor (kept inside the actor set so the
    ///      votes==supply invariant stays well-defined).
    function delegateTo(uint256 fromSeed, uint256 toSeed) public useActor(fromSeed) {
        address to = actors[bound(toSeed, 0, ACTOR_COUNT - 1)];
        try staking.delegate(to) {} catch {}
    }

    // ── reward inflows (handler == owner == feeDispatcher) ──────────────────────

    function sendFees(uint256 amount) public {
        amount = bound(amount, 0, 100 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(staking).call{value: amount}("");
        if (ok) ghost_rewardsIn += amount;
    }

    /// @dev Biased toward the rounding boundary: amounts straddling rewardsDuration
    ///      (in wei) are exactly where notify can produce scheduled < leftover.
    function sendTinyFees(uint256 amount) public {
        amount = bound(amount, 0, 5 * staking.rewardsDuration());
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(staking).call{value: amount}("");
        if (ok) ghost_rewardsIn += amount;
    }

    function addBonus(uint256 amount) public {
        amount = bound(amount, 1, 50 ether);
        vm.deal(address(this), address(this).balance + amount);
        try staking.addBonus{value: amount}() {
            ghost_rewardsIn += amount;
        } catch {}
    }

    // ── owner / admin actions ───────────────────────────────────────────────

    function pauseToggle() public {
        if (staking.paused()) {
            staking.unpause();
        } else {
            staking.pause();
        }
    }

    function setRewardsDuration(uint256 dur) public {
        dur = bound(dur, 1 hours, 30 days);
        try staking.setRewardsDuration(dur) {} catch {}
    }

    // ── time ────────────────────────────────────────────────────────────────

    function warp(uint256 secs) public {
        secs = bound(secs, 1, 10 days);
        vm.warp(block.timestamp + secs);
    }
}

contract StakingInvariantTest is Test {
    Staking internal staking;
    StakingHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000); // deterministic non-zero start for timestamp checkpoints

        Staking impl = new Staking();
        // Owner and feeDispatcher are the (yet-to-be-deployed) handler so it can
        // drive every path. Predict its address to wire initialize() up front.
        handler = StakingHandler(payable(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeCall(Staking.initialize, (address(handler), address(handler), 1 hours))
        );
        staking = Staking(payable(address(proxy)));

        StakingHandler deployed = new StakingHandler(staking);
        require(address(deployed) == address(handler), "handler addr mismatch");

        targetContract(address(handler));
    }

    // ── value safety ──────────────────────────────────────────────────────────

    /// @notice Core solvency: the contract always holds at least everything it owes
    ///         (principal + unclaimed committed rewards + parked rewards). The
    ///         invariant the M-1 double-park bug violated.
    function invariant_solvent() public view {
        uint256 reserved = staking.totalSupply() + staking.committedRewards() + staking.pendingRewards();
        assertGe(address(staking).balance, reserved, "insolvent: balance < reserved");
    }

    /// @notice Principal is always fully backed by native balance.
    function invariant_principalBacked() public view {
        assertGe(address(staking).balance, staking.totalSupply(), "principal not backed");
    }

    /// @notice Global native conservation: every wei in is either still held or was
    ///         paid out through a tracked exit. Nothing is created or destroyed.
    function invariant_conservation() public view {
        uint256 totalIn = handler.ghost_principalIn() + handler.ghost_rewardsIn();
        uint256 totalOut = handler.ghost_principalOut() + handler.ghost_rewardsOut();
        assertEq(address(staking).balance, totalIn - totalOut, "native not conserved");
    }

    // ── reward accounting ─────────────────────────────────────────────────────

    /// @notice Committed reward accounting never goes negative.
    function invariant_claimsBounded() public view {
        assertLe(staking.lifetimeRewardsClaimed(), staking.lifetimeRewardsScheduled(), "claimed > scheduled");
    }

    /// @notice Snapshotted-but-unclaimed rewards are always covered by the
    ///         outstanding committed reward pool.
    function invariant_accruedCovered() public view {
        uint256 sumAccrued;
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sumAccrued += staking.userAccruedRewards(handler.actorAt(i));
        }
        assertLe(sumAccrued, staking.committedRewards(), "accrued exceeds committed pool");
    }

    // ── token / votes ─────────────────────────────────────────────────────────

    /// @notice xDUAL supply equals outstanding principal at all times.
    function invariant_supplyEqualsPrincipal() public view {
        uint256 principalOutstanding = handler.ghost_principalIn() - handler.ghost_principalOut();
        assertEq(staking.totalSupply(), principalOutstanding, "supply != outstanding principal");
    }

    /// @notice The actor set holds the entire supply (no tokens escape elsewhere).
    function invariant_balancesSumToSupply() public view {
        uint256 sumBal;
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sumBal += staking.balanceOf(handler.actorAt(i));
        }
        assertEq(sumBal, staking.totalSupply(), "balances != supply");
    }

    /// @notice No voting power leaks to the zero-address delegate: the sum of every
    ///         holder's active votes equals total supply (guards auto-delegation).
    function invariant_votesEqualSupply() public view {
        uint256 sumVotes;
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sumVotes += staking.getVotes(handler.actorAt(i));
        }
        assertEq(sumVotes, staking.totalSupply(), "votes != supply");
    }

    /// @notice Every holder with a non-zero balance has an active delegate, so
    ///         their governance weight is never silently dormant.
    function invariant_holdersHaveDelegate() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            address a = handler.actorAt(i);
            if (staking.balanceOf(a) > 0) {
                assertTrue(staking.delegates(a) != address(0), "holder without delegate");
            }
        }
    }

    // ── liveness ──────────────────────────────────────────────────────────────

    /// @notice Any holder can always fully exit (unstake principal + claim rewards)
    ///         without reverting, even while paused. Probed via snapshot/revert.
    function invariant_holdersCanExit() public {
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            address a = handler.actorAt(i);
            bool hasStake = staking.balanceOf(a) > 0;
            bool hasReward = staking.previewRewards(a) > 0 || staking.userAccruedRewards(a) > 0;
            if (!hasStake && !hasReward) continue;

            uint256 snap = vm.snapshotState();
            vm.prank(a);
            staking.exit(); // must not revert
            vm.revertToState(snap);
        }
    }
}
