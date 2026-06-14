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

/// @title Staking
/// @notice Native DUAL staking contract that mints xDUAL tokens 1:1 and
///         streams batch fees to stakers over a configurable reward period.
contract Staking is
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

    /// @notice Global cumulative fee rewards per xDUAL (scaled by PRECISION)
    uint256 public rewardPerTokenStored;

    /// @notice Per-user snapshot of `rewardPerTokenStored` at last action.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Per-user accrued but unclaimed DUAL rewards.
    mapping(address => uint256) public userAccruedRewards;

    /// @notice Rewards committed to streams and not yet claimed by stakers.
    uint256 public committedRewards;

    /// @notice Lifetime rewards committed to streams, excluding parked dust.
    uint256 public lifetimeRewardsScheduled;

    /// @notice Lifetime rewards claimed by stakers.
    uint256 public lifetimeRewardsClaimed;

    /// @notice FeeDispatcher address authorized to send fees
    address public feeDispatcher;

    /// @notice DUAL distributed per second during the active reward period.
    uint256 public rewardRate;

    /// @notice Timestamp of the last `rewardPerTokenStored` update.
    uint256 public lastUpdateTime;

    /// @notice Timestamp at which the current reward stream finishes.
    uint256 public periodFinish;

    /// @notice Length of each reward streaming period.
    uint256 public rewardsDuration;

    /// @notice DUAL received but not yet notified (e.g. arrived while supply == 0,
    ///         or rounded out of a previous notification). Folded into the next notify.
    uint256 public pendingRewards;

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

    /// @notice Stake DUAL and receive xDUAL at a 1:1 rate.
    function stake() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();

        // msg.sender's reward accrual is handled by _mint -> _update -> _updateReward.
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
        // `leftover` was already committed by the previous stream.
        if (scheduled >= leftover) {
            uint256 additional = scheduled - leftover;
            committedRewards += additional;
            lifetimeRewardsScheduled += additional;
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
        if (totalSupply() == 0 || paused()) {
            _parkRewards(amount);
            return;
        }

        uint256 toNotify = amount + pendingRewards;
        pendingRewards = 0;
        _notifyReward(toNotify);
    }

    uint256[43] private __gap;
}
