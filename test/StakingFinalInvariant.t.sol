// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakingV1} from "../src/legacy/StakingV1.sol";
import {StakingFinal} from "../src/StakingFinal.sol";

/// @dev Drives randomized sequences of every state-changing entrypoint against a
///      proxy that has ALREADY been migrated from v1 (`StakingV1`) to v2
///      (`StakingFinal`) carrying non-zero reward state through the real
///      `upgradeToAndCall(reinitializePermit)` path. Encodes the solvency proof
///      from the security review: balance always covers principal + committed + parked, and
///      outstanding accrued rewards never exceed the committed pool — proving the
///      cumulative→outstanding migration seed is self-consistent under any
///      subsequent operation mix. Handler is BOTH owner and feeDispatcher.
contract StakingFinalHandler is Test {
    StakingFinal public immutable staking;

    uint256 public constant ACTOR_COUNT = 4;
    address[] public actors;

    // Ghost accounting of native flows, cross-checked by invariant_conservation.
    uint256 public ghost_principalIn;
    uint256 public ghost_principalOut;
    uint256 public ghost_rewardsIn;
    uint256 public ghost_rewardsOut;

    address internal currentActor;

    modifier useActor(uint256 seed) {
        currentActor = actors[bound(seed, 0, ACTOR_COUNT - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(StakingFinal _staking) {
        staking = _staking;
        for (uint256 i; i < ACTOR_COUNT; i++) {
            actors.push(makeAddr(string(abi.encodePacked("uactor", vm.toString(i)))));
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

    /// @dev Biased toward the rounding boundary (amounts straddling rewardsDuration
    ///      in wei), where notify can produce scheduled < leftover.
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

contract StakingFinalInvariantTest is Test {
    StakingFinal internal staking;
    StakingFinalHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000); // deterministic non-zero start for timestamp checkpoints

        // 1. Deploy a v1 proxy with handler as owner + feeDispatcher.
        StakingV1 v1Impl = new StakingV1();
        handler = StakingFinalHandler(payable(computeCreateAddress(address(this), vm.getNonce(address(this)) + 1)));
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(v1Impl), abi.encodeCall(StakingV1.initialize, (address(handler), address(handler), 1 hours))
        );
        StakingFinalHandler deployed = new StakingFinalHandler(StakingFinal(payable(address(proxy))));
        require(address(deployed) == address(handler), "handler addr mismatch");
        staking = StakingFinal(payable(address(proxy)));

        // 2. Build NON-ZERO v1 reward state so the migration seed is exercised:
        //    stake → fees → partial elapse → partial claim leaves dispatched > claimed.
        handler.stake(0, 10 ether);
        handler.stake(1, 7 ether);
        handler.sendFees(5 ether);
        handler.warp(600); // ~1/6 through the 1h stream
        handler.claim(0);
        require(StakingV1(payable(address(proxy))).totalFeesDispatched() > 0, "seed: no dispatched");
        require(StakingV1(payable(address(proxy))).totalRewardsClaimed() > 0, "seed: no claimed");

        // 3. Upgrade v1 → v2 atomically with the migration (as owner).
        StakingFinal newImpl = new StakingFinal();
        vm.prank(address(handler));
        staking.upgradeToAndCall(address(newImpl), abi.encodeCall(StakingFinal.reinitializePermit, ()));

        // Sanity: the post-upgrade invariants must already hold at the migrated state.
        assertEq(staking.committedRewards(), staking.lifetimeRewardsScheduled() - staking.lifetimeRewardsClaimed());
        assertGe(
            address(staking).balance,
            staking.totalSupply() + staking.committedRewards() + staking.pendingRewards(),
            "migrated state insolvent"
        );

        // 4. Fuzz the upgraded proxy.
        targetContract(address(handler));
    }

    // ── core solvency proof ─────────────────────────────────────────────────────

    /// @notice THE solvency invariant: the contract always holds at least everything
    ///         it owes — principal + outstanding committed rewards + parked rewards.
    function invariant_solvent() public view {
        uint256 reserved = staking.totalSupply() + staking.committedRewards() + staking.pendingRewards();
        assertGe(address(staking).balance, reserved, "insolvent: balance < reserved");
    }

    /// @notice Principal is always fully backed by native balance.
    function invariant_principalBacked() public view {
        assertGe(address(staking).balance, staking.totalSupply(), "principal not backed");
    }

    /// @notice Outstanding snapshotted rewards never exceed the committed pool, so
    ///         `committedRewards -= amount` on claim can never underflow
    ///         (the over-collateralization half of the proof).
    function invariant_accruedCovered() public view {
        uint256 sumAccrued;
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sumAccrued += staking.userAccruedRewards(handler.actorAt(i));
        }
        assertLe(sumAccrued, staking.committedRewards(), "accrued exceeds committed pool");
    }

    /// @notice Lifetime claimed never exceeds lifetime scheduled.
    function invariant_claimsBounded() public view {
        assertLe(staking.lifetimeRewardsClaimed(), staking.lifetimeRewardsScheduled(), "claimed > scheduled");
    }

    /// @notice Native conservation across the v1 seed + v2 fuzz: balance == in − out.
    function invariant_conservation() public view {
        uint256 totalIn = handler.ghost_principalIn() + handler.ghost_rewardsIn();
        uint256 totalOut = handler.ghost_principalOut() + handler.ghost_rewardsOut();
        assertEq(address(staking).balance, totalIn - totalOut, "native not conserved");
    }

    // ── upgrade-specific invariants ──────────────────────────────────────────────

    /// @notice The legacy `totalStaked` mirror stays equal to xDUAL supply.
    function invariant_totalStakedMirrorsSupply() public view {
        assertEq(staking.totalStaked(), staking.totalSupply(), "totalStaked != totalSupply");
    }

    /// @notice The ERC20Permit domain initialised by the migration never goes blank.
    function invariant_permitDomainInitialised() public view {
        assertTrue(staking.DOMAIN_SEPARATOR() != bytes32(0), "permit domain blank");
    }

    /// @notice xDUAL supply equals outstanding principal at all times.
    function invariant_supplyEqualsPrincipal() public view {
        uint256 principalOutstanding = handler.ghost_principalIn() - handler.ghost_principalOut();
        assertEq(staking.totalSupply(), principalOutstanding, "supply != outstanding principal");
    }

    /// @notice Sum of active votes equals total supply (guards auto-delegation).
    function invariant_votesEqualSupply() public view {
        uint256 sumVotes;
        for (uint256 i; i < handler.ACTOR_COUNT(); i++) {
            sumVotes += staking.getVotes(handler.actorAt(i));
        }
        assertEq(sumVotes, staking.totalSupply(), "votes != supply");
    }

    // ── liveness ──────────────────────────────────────────────────────────────

    /// @notice Any holder can always fully exit, even while paused.
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
