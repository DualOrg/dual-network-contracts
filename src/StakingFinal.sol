// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title StakingFinal
/// @notice Upgrade implementation for the live Staking proxy. The reward/staking
///         logic below is byte-for-byte identical to the canonical `Staking`
///         contract; the only differences are storage bookkeeping required to
///         preserve the deployed v1 slot layout, plus a one-time reinitializer
///         that (a) wires up the ERC20Permit domain that v1 lacked and
///         (b) converts the `committedRewards` slot from v1's cumulative
///         representation to the live-outstanding representation this logic uses.
/// @dev    Storage layout for slots 0..11 is FROZEN to match deployed v1. New
///         state (`committedRewards`) is appended into the reserved gap.
contract StakingFinal is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /// @notice Precision multiplier for reward calculations
    uint256 private constant PRECISION = 1e18;

    /// @notice Min/max bounds for the streaming period (sanity guards on owner setter).
    uint256 private constant MIN_REWARDS_DURATION = 1 hours;
    uint256 private constant MAX_REWARDS_DURATION = 30 days;

    // --- Storage (slots 0..11 FROZEN to match deployed v1) ---

    /// @notice Global cumulative fee rewards per xDUAL (scaled by PRECISION)
    uint256 public rewardPerTokenStored; // slot 0

    /// @notice Per-user snapshot of `rewardPerTokenStored` at last action.
    mapping(address => uint256) public userRewardPerTokenPaid; // slot 1

    /// @notice Per-user accrued but unclaimed DUAL rewards.
    mapping(address => uint256) public userAccruedRewards; // slot 2

    /// @notice Total DUAL staked (principal only, excludes fee reserves). Leave it
    ///         to keep the storage consistent with the deployed proxy; it mirrors
    ///         `totalSupply()` (xDUAL is minted 1:1 with DUAL) and the core reward
    ///         logic reads `totalSupply()`, exactly like the canonical contract.
    uint256 public totalStaked; // slot 3

    /// @notice Cumulative external reward DUAL ingested — fees via `receive()` and
    ///         owner bonuses via `addBonus()` — counted exactly once at receipt and
    ///         never reduced. Rewards that are parked and later re-scheduled are NOT
    ///         counted again, so this is a faithful lifetime inflow total.
    /// @dev    Analytics only: no reward, claim, or solvency path reads it.
    ///         `committedRewards` is the authoritative outstanding figure;
    ///         `lifetimeRewardsReceived - lifetimeRewardsClaimed` is NOT live
    ///         outstanding (it equals committed + parked). Slot reused from v1's
    ///         `totalFeesDispatched`; the value is preserved at the upgrade (0 on
    ///         the live proxy, so from migration onward this is a clean cumulative
    ///         inflow counter). v1 maintained this slot as a net figure;
    ///         StakingFinal counts gross inflow at ingestion instead.
    uint256 public lifetimeRewardsReceived; // slot 4

    /// @notice Lifetime rewards claimed by stakers.
    /// @dev    Slot reused from v1's `totalRewardsClaimed`; pure rename, value preserved.
    uint256 public lifetimeRewardsClaimed; // slot 5

    /// @notice FeeDispatcher address authorized to send fees
    address public feeDispatcher; // slot 6

    /// @notice DUAL distributed per second during the active reward period.
    uint256 public rewardRate; // slot 7

    /// @notice Timestamp of the last `rewardPerTokenStored` update.
    uint256 public lastUpdateTime; // slot 8

    /// @notice Timestamp at which the current reward stream finishes.
    uint256 public periodFinish; // slot 9

    /// @notice Length of each reward streaming period.
    uint256 public rewardsDuration; // slot 10

    /// @notice DUAL received but not yet notified (e.g. arrived while supply == 0,
    ///         or rounded out of a previous notification). Folded into the next notify.
    uint256 public pendingRewards; // slot 11

    /// @notice Rewards committed to streams and not yet claimed by stakers.
    /// @dev    Live outstanding balance, and the only accounting field read by
    ///         logic (`_availableForRewards`). Appended in this upgrade (was
    ///         reserved gap, reads 0 on the live proxy); seeded once in
    ///         `reinitializePermit()` to `lifetimeRewardsReceived - lifetimeRewardsClaimed`.
    uint256 public committedRewards; // slot 12 (new)

    // --- Events ---

    event Staked(address indexed user, uint256 dualAmount, uint256 xDualMinted);
    event Unstaked(address indexed user, uint256 dualAmount, uint256 xDualBurned);
    event FeesReceived(address indexed from, uint256 amount);
    event RewardsNotified(uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event RewardsParked(uint256 amount, uint256 totalPending);
    event RewardsClaimed(address indexed user, uint256 amount);
    event BonusAdded(address indexed from, uint256 amount);
    event FeeDispatcherUpdated(address indexed oldDispatcher, address indexed newDispatcher);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);

    error Unauthorized();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();
    error NothingToClaim();
    error InvalidAddress();
    error InvalidDuration();
    error UnchangedValue();
    error RewardRateTooHigh();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the staking contract.
    /// @dev    Fresh deployments only — the live proxy is already initialized at
    ///         version 1. Existing proxies pick up the ERC20Permit domain and the
    ///         committedRewards seed via `reinitializePermit`.
    /// @param _owner Contract owner (can upgrade, pause, configure).
    /// @param _feeDispatcher FeeDispatcher address.
    /// @param _rewardsDuration Length of each fee streaming period in seconds.
    function initialize(address _owner, address _feeDispatcher, uint256 _rewardsDuration) public initializer {
        if (_owner == address(0)) revert InvalidAddress();
        if (_rewardsDuration < MIN_REWARDS_DURATION || _rewardsDuration > MAX_REWARDS_DURATION) {
            revert InvalidDuration();
        }
        if (_feeDispatcher == address(0)) revert InvalidAddress();

        __ERC20_init("Staked DUAL", "xDUAL");
        __ERC20Permit_init("Staked DUAL");
        __ERC20Votes_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        feeDispatcher = _feeDispatcher;
        rewardsDuration = _rewardsDuration;

        emit FeeDispatcherUpdated(address(0), _feeDispatcher);
        emit RewardsDurationUpdated(0, _rewardsDuration);
    }

    /// @notice One-time migration run atomically with the upgrade of an existing proxy.
    /// @dev    Invoke via `upgradeToAndCall(newImpl, abi.encodeCall(
    ///         StakingFinal.reinitializePermit, ()))`. It:
    ///         1. initialises the ERC20Permit (EIP-712) domain that v1 never set; and
    ///         2. seeds the new `committedRewards` field (live outstanding) from the
    ///            preserved v1 counters. The two existing slots
    ///            (`lifetimeRewardsReceived` = v1 `totalFeesDispatched`,
    ///            `lifetimeRewardsClaimed` = v1 `totalRewardsClaimed`) are left
    ///            untouched. Safe because claimed <= dispatched.
    function reinitializePermit() external onlyOwner reinitializer(2) {
        __ERC20Permit_init("Staked DUAL");

        committedRewards = lifetimeRewardsReceived - lifetimeRewardsClaimed; // outstanding = dispatched - claimed
    }

    /// @notice Stake DUAL and receive xDUAL at a 1:1 rate.
    function stake() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();

        // msg.sender's reward accrual is handled by _mint -> _update -> _updateReward.
        totalStaked += msg.value;
        _mint(msg.sender, msg.value);

        // Only bootstrap a stream from parked rewards when none is active. A stake
        // must not re-notify a live stream: doing so would let any account
        // permissionlessly re-amortise the leftover over a fresh duration (lowering
        // the rate and pushing periodFinish out) and keep setRewardsDuration locked.
        // Parked dust accumulated during an active period is folded by the next fee
        // inflow or once the current period ends.
        if (pendingRewards > 0 && block.timestamp >= periodFinish) {
            uint256 rewardsToNotify = pendingRewards;
            pendingRewards = 0;
            _notifyReward(rewardsToNotify);
        }

        emit Staked(msg.sender, msg.value, msg.value);
    }

    /// @notice Burn xDUAL and reclaim DUAL at a 1:1 rate.
    /// @dev Pending rewards are accrued to the user's unclaimed balance but
    ///      NOT auto-paid; call `claimRewards()` separately.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        // msg.sender's reward accrual is handled by _burn -> _update -> _updateReward.
        _unstakePrincipal(msg.sender, amount);

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Unstaked(msg.sender, amount, amount);
    }

    /// @notice Claim all accumulated DUAL fee rewards.
    /// @return amount DUAL transferred to the caller.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _updateReward(msg.sender);

        amount = _claimAccrued(msg.sender);
        if (amount == 0) revert NothingToClaim();

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Claim all accumulated rewards and unstake all xDUAL in one transaction.
    /// @return staked   DUAL returned as principal.
    /// @return rewards  DUAL transferred as fee rewards.
    function exit() external nonReentrant returns (uint256 staked, uint256 rewards) {
        staked = balanceOf(msg.sender);

        if (staked > 0) {
            // _burn -> _update accrues msg.sender's rewards before reducing shares.
            _unstakePrincipal(msg.sender, staked);
            emit Unstaked(msg.sender, staked, staked);
        } else {
            // No shares to burn (so no _update hook); accrue/advance explicitly.
            _updateReward(msg.sender);
        }

        rewards = _claimAccrued(msg.sender);

        if (staked == 0 && rewards == 0) revert NothingToClaim();

        if (rewards > 0) {
            emit RewardsClaimed(msg.sender, rewards);
        }

        uint256 total = staked + rewards;
        (bool success,) = payable(msg.sender).call{value: total}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Last timestamp at which rewards are still being streamed.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Live `rewardPerTokenStored` including unsnapshot streaming since `lastUpdateTime`.
    function rewardPerToken() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return rewardPerTokenStored;
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (elapsed * rewardRate * PRECISION) / supply;
    }

    /// @notice Preview how much DUAL `user` can claim right now.
    function previewRewards(address user) external view returns (uint256) {
        uint256 shares = balanceOf(user);
        uint256 rpt = rewardPerToken();
        uint256 paid = userRewardPerTokenPaid[user];
        uint256 fresh = paid >= rpt ? 0 : (shares * (rpt - paid)) / PRECISION;
        return userAccruedRewards[user] + fresh;
    }

    /// @notice Set the FeeDispatcher address authorized to send fees.
    /// @dev Rejects zero-address and no-op writes.
    function setFeeDispatcher(address _feeDispatcher) external onlyOwner {
        if (_feeDispatcher == address(0)) revert InvalidAddress();
        address oldDispatcher = feeDispatcher;
        if (_feeDispatcher == oldDispatcher) revert UnchangedValue();
        feeDispatcher = _feeDispatcher;
        emit FeeDispatcherUpdated(oldDispatcher, _feeDispatcher);
    }

    /// @notice Update the streaming period length. Only callable when no period
    ///         is currently active (block.timestamp >= periodFinish) to avoid
    ///         re-shaping a live distribution under stakers' feet.
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp < periodFinish) revert InvalidDuration();
        if (_rewardsDuration < MIN_REWARDS_DURATION || _rewardsDuration > MAX_REWARDS_DURATION) {
            revert InvalidDuration();
        }
        if (_rewardsDuration == rewardsDuration) revert UnchangedValue();
        emit RewardsDurationUpdated(rewardsDuration, _rewardsDuration);
        rewardsDuration = _rewardsDuration;
    }

    /// @notice Pause the contract (blocks new stakes; exits remain open).
    /// @dev Intentional design: stakers can always `unstake()` and
    ///      `claimRewards()` to recover funds, even paused. Fees and bonuses
    ///      received while paused are parked into `pendingRewards` instead of
    ///      streamed, and scheduled on `unpause()` (or the next stake).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract and schedule any rewards parked while paused.
    function unpause() external onlyOwner {
        _unpause();

        if (totalSupply() > 0 && pendingRewards > 0) {
            uint256 toNotify = pendingRewards;
            pendingRewards = 0;
            _notifyReward(toNotify);
        }
    }

    /// @dev Synchronise the global accumulator and snapshot `account`.
    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            uint256 shares = balanceOf(account);
            if (shares > 0) {
                uint256 paid = userRewardPerTokenPaid[account];
                if (rewardPerTokenStored > paid) {
                    userAccruedRewards[account] += (shares * (rewardPerTokenStored - paid)) / PRECISION;
                }
            }
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _unstakePrincipal(address user, uint256 amount) internal {
        totalStaked -= amount;
        _burn(user, amount);
        _parkRemainingRewardsIfEmpty();
    }

    function _claimAccrued(address user) internal returns (uint256 amount) {
        amount = userAccruedRewards[user];
        if (amount == 0) return 0;

        userAccruedRewards[user] = 0;
        committedRewards -= amount;
        lifetimeRewardsClaimed += amount;
    }

    function _notifyReward(uint256 amount) internal {
        _updateReward(address(0));

        uint256 leftover = _leftoverRewards();

        uint256 totalToSchedule = amount + leftover;
        (uint256 newRate, uint256 scheduled, uint256 dust) = _rewardSchedule(totalToSchedule);

        _parkRewards(dust);
        if (scheduled > _availableForRewards() + leftover) {
            revert RewardRateTooHigh();
        }

        _replaceLeftoverRewards(leftover, scheduled);

        if (scheduled == 0) {
            _closeRewardPeriod();
            return;
        }

        _startRewardPeriod(newRate);

        emit RewardsNotified(amount, newRate, periodFinish);
    }

    function _parkRemainingRewardsIfEmpty() internal {
        if (totalSupply() != 0 || block.timestamp >= periodFinish) return;

        uint256 leftover = _leftoverRewards();
        committedRewards -= leftover;
        _parkRewards(leftover);

        _closeRewardPeriod();
    }

    function _availableForRewards() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        // Pending rewards are folded into `amount` before notify; newly created
        // dust is intentionally not part of the active schedule.
        uint256 promised = totalSupply() + committedRewards;
        if (balance <= promised) return 0;
        return balance - promised;
    }

    function _leftoverRewards() internal view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }

    function _rewardSchedule(uint256 totalToSchedule)
        internal
        view
        returns (uint256 newRate, uint256 scheduled, uint256 dust)
    {
        newRate = totalToSchedule / rewardsDuration;
        scheduled = newRate * rewardsDuration;
        dust = totalToSchedule - scheduled;
    }

    function _replaceLeftoverRewards(uint256 leftover, uint256 scheduled) internal {
        // `leftover` was already committed by the previous stream. Only the live
        // committed pool moves here; lifetime inflow is counted once at ingestion
        // (see `_ingestRewards`), so parked-then-rescheduled rewards are never
        // double-counted.
        if (scheduled >= leftover) {
            committedRewards += scheduled - leftover;
        } else {
            committedRewards -= leftover - scheduled;
        }
    }

    function _parkRewards(uint256 amount) internal {
        if (amount == 0) return;
        pendingRewards += amount;
        emit RewardsParked(amount, pendingRewards);
    }

    function _closeRewardPeriod() internal {
        rewardRate = 0;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp;
    }

    function _startRewardPeriod(uint256 newRate) internal {
        rewardRate = newRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (from != address(0)) _updateReward(from);
        if (to != address(0) && to != from) _updateReward(to);

        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }

        super._update(from, to, value);
    }

    /// @dev Resolve the `Nonces` diamond inherited via both ERC20Permit and Votes.
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Use timestamps instead of block numbers for governance checkpoints.
    ///      Block numbers are unreliable on Arbitrum/Orbit chains; OpenZeppelin
    ///      recommends timestamp mode for L2 deployments.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev EIP-6372 mode descriptor.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @notice Inject a bonus into the reward stream, distributing it
    ///         proportionally to all current stakers. Callable by the owner only.
    /// @dev Mirrors the receive() logic without the feeDispatcher restriction.
    function addBonus() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();

        emit BonusAdded(msg.sender, msg.value);
        _ingestRewards(msg.value);
    }

    /// @notice Receive DUAL from the FeeDispatcher and start/extend a stream.
    /// @dev If no one is currently staked, parks the funds and notifies on the
    ///      next stake().
    receive() external payable nonReentrant {
        if (msg.sender != feeDispatcher) revert Unauthorized();
        if (msg.value == 0) return;

        emit FeesReceived(msg.sender, msg.value);
        _ingestRewards(msg.value);
    }

    /// @dev Park-or-notify: hold funds (until the next stake / unpause) when there
    ///      is no supply yet OR the contract is paused; otherwise fold pending
    ///      rewards in and start/extend the stream.
    function _ingestRewards(uint256 amount) internal {
        // Count every external reward inflow exactly once, at receipt — whether it
        // is parked now or streamed immediately, and regardless of any later
        // park / re-schedule. Keeps lifetimeRewardsReceived a true cumulative
        // inflow total (no double-counting of recycled parked rewards).
        lifetimeRewardsReceived += amount;

        if (totalSupply() == 0 || paused()) {
            _parkRewards(amount);
            return;
        }

        uint256 toNotify = amount + pendingRewards;
        pendingRewards = 0;
        _notifyReward(toNotify);
    }

    uint256[42] private __gap;
}
