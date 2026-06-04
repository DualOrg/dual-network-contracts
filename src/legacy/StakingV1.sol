
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title StakingV1 (verified deployed v1 — reference for upgrade tests)
/// @notice Native DUAL staking contract that mints xDUAL tokens 1:1 and
///         streams batch fees to stakers over a configurable reward period.
contract StakingV1 is
    Initializable,
    ERC20Upgradeable,
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

    /// @notice Total DUAL staked (principal only, excludes fee reserves).
    uint256 public totalStaked;

    /// @notice DUAL committed to reward streams. Increments on notify, decrements on claim.
    uint256 public totalFeesDispatched;

    /// @notice Lifetime rewards claimed by stakers.
    uint256 public totalRewardsClaimed;

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
    event Unstaked(
        address indexed user,
        uint256 dualAmount,
        uint256 xDualBurned
    );
    event FeesReceived(address indexed from, uint256 amount);
    event RewardsNotified(
        uint256 amount,
        uint256 rewardRate,
        uint256 periodFinish
    );
    event RewardsParked(uint256 amount, uint256 totalPending);
    event RewardsClaimed(address indexed user, uint256 amount);
    event BonusAdded(address indexed from, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);
    event FeeDispatcherUpdated(
        address indexed oldDispatcher,
        address indexed newDispatcher
    );
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
    error ExceedsWithdrawableSurplus();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the staking contract.
    /// @param _owner Contract owner (can upgrade, pause, configure).
    /// @param _feeDispatcher FeeDispatcher address).
    /// @param _rewardsDuration Length of each fee streaming period in seconds.
    function initialize(
        address _owner,
        address _feeDispatcher,
        uint256 _rewardsDuration
    ) public initializer {
        if (_owner == address(0)) revert InvalidAddress();
        if (
            _rewardsDuration < MIN_REWARDS_DURATION ||
            _rewardsDuration > MAX_REWARDS_DURATION
        ) {
            revert InvalidDuration();
        }
        if (_feeDispatcher == address(0)) revert InvalidAddress();

        __ERC20_init("Staked DUAL", "xDUAL");
        __ERC20Votes_init();
        __Ownable_init(_owner);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        feeDispatcher = _feeDispatcher;
        rewardsDuration = _rewardsDuration;

        if (_feeDispatcher != address(0)) {
            emit FeeDispatcherUpdated(address(0), _feeDispatcher);
        }
        emit RewardsDurationUpdated(0, _rewardsDuration);
    }

    /// @notice Stake DUAL and receive xDUAL at a 1:1 rate.
    function stake() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();

        _updateReward(msg.sender);

        uint256 rewardsToNotify = pendingRewards;

        totalStaked += msg.value;
        _mint(msg.sender, msg.value);

        if (delegates(msg.sender) == address(0)) {
            _delegate(msg.sender, msg.sender);
        }

        if (rewardsToNotify > 0) {
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

        _updateReward(msg.sender);

        totalStaked -= amount;
        _burn(msg.sender, amount);
        _parkRemainingRewardsIfEmpty();

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Unstaked(msg.sender, amount, amount);
    }

    /// @notice Claim all accumulated DUAL fee rewards.
    /// @return amount DUAL transferred to the caller.
    function claimRewards() external nonReentrant returns (uint256 amount) {
        _updateReward(msg.sender);

        amount = userAccruedRewards[msg.sender];
        if (amount == 0) revert NothingToClaim();

        userAccruedRewards[msg.sender] = 0;
        totalRewardsClaimed += amount;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Claim all accumulated rewards and unstake all xDUAL in one transaction.
    /// @return staked   DUAL returned as principal.
    /// @return rewards  DUAL transferred as fee rewards.
    function exit()
        external
        nonReentrant
        returns (uint256 staked, uint256 rewards)
    {
        _updateReward(msg.sender);

        staked = balanceOf(msg.sender);
        rewards = userAccruedRewards[msg.sender];

        if (staked == 0 && rewards == 0) revert NothingToClaim();

        if (staked > 0) {
            totalStaked -= staked;
            _burn(msg.sender, staked);
            _parkRemainingRewardsIfEmpty();
            emit Unstaked(msg.sender, staked, staked);
        }

        if (rewards > 0) {
            userAccruedRewards[msg.sender] = 0;
            totalRewardsClaimed += rewards;
            emit RewardsClaimed(msg.sender, rewards);
        }

        uint256 total = staked + rewards;
        (bool success, ) = payable(msg.sender).call{value: total}("");
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
        return
            rewardPerTokenStored + (elapsed * rewardRate * PRECISION) / supply;
    }

    /// @notice Preview how much DUAL `user` can claim right now.
    function previewRewards(address user) external view returns (uint256) {
        uint256 shares = balanceOf(user);
        uint256 rpt = rewardPerToken();
        uint256 paid = userRewardPerTokenPaid[user];
        uint256 fresh = paid >= rpt ? 0 : (shares * (rpt - paid)) / PRECISION;
        return userAccruedRewards[user] + fresh;
    }

    /// @notice Returns DUAL the owner can emergency-withdraw without touching
    ///         staker principal, scheduled rewards, or parked rewards.
    function withdrawableSurplus() public view returns (uint256) {
        uint256 reserved = totalStaked +
            (totalFeesDispatched - totalRewardsClaimed) +
            pendingRewards;
        uint256 balance = address(this).balance;
        if (balance <= reserved) return 0;
        return balance - reserved;
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
        if (
            _rewardsDuration < MIN_REWARDS_DURATION ||
            _rewardsDuration > MAX_REWARDS_DURATION
        ) {
            revert InvalidDuration();
        }
        if (_rewardsDuration == rewardsDuration) revert UnchangedValue();
        emit RewardsDurationUpdated(rewardsDuration, _rewardsDuration);
        rewardsDuration = _rewardsDuration;
    }

    /// @notice Pause the contract (blocks new stakes; exits remain open).
    /// @dev Intentional design: pause halts INFLOWS only. Stakers can always
    ///      `unstake()` and `claimRewards()` to recover funds, even paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Emergency withdrawal of native DUAL, bounded by withdrawableSurplus().
    function emergencyWithdraw(
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > withdrawableSurplus()) revert ExceedsWithdrawableSurplus();

        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();

        emit EmergencyWithdraw(to, amount);
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
                    userAccruedRewards[account] +=
                        (shares * (rewardPerTokenStored - paid)) /
                        PRECISION;
                }
            }
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _notifyReward(uint256 amount) internal {
        _updateReward(address(0));

        uint256 leftover;
        if (block.timestamp < periodFinish) {
            leftover = (periodFinish - block.timestamp) * rewardRate;
        }

        uint256 totalToSchedule = amount + leftover;
        uint256 newRate = totalToSchedule / rewardsDuration;
        uint256 scheduled = newRate * rewardsDuration;
        uint256 dust = totalToSchedule - scheduled;

        if (dust > 0) {
            pendingRewards += dust;
            emit RewardsParked(dust, pendingRewards);
        }

        if (scheduled > _availableForRewards() + leftover) {
            revert RewardRateTooHigh();
        }

        if (scheduled >= leftover) {
            totalFeesDispatched += scheduled - leftover;
        } else {
            totalFeesDispatched -= leftover - scheduled;
        }

        if (scheduled == 0) {
            rewardRate = 0;
            lastUpdateTime = block.timestamp;
            periodFinish = block.timestamp;
            return;
        }

        rewardRate = newRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardsNotified(amount, newRate, periodFinish);
    }

    function _parkRemainingRewardsIfEmpty() internal {
        if (totalSupply() != 0 || block.timestamp >= periodFinish) return;

        uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
        if (leftover > 0) {
            totalFeesDispatched -= leftover;
            pendingRewards += leftover;
            emit RewardsParked(leftover, pendingRewards);
        }

        rewardRate = 0;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp;
    }

    function _availableForRewards() internal view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 promised = totalStaked +
            (totalFeesDispatched - totalRewardsClaimed);
        if (balance <= promised) return 0;
        return balance - promised;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        if (from != address(0)) _updateReward(from);
        if (to != address(0) && to != from) _updateReward(to);

        super._update(from, to, value);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

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
    receive() external payable {
        if (msg.sender != feeDispatcher) revert Unauthorized();
        if (msg.value == 0) return;

        emit FeesReceived(msg.sender, msg.value);
        _ingestRewards(msg.value);
    }

    /// @dev Park-or-notify: if no supply yet, hold funds until the next stake;
    ///      otherwise fold pending rewards in and start/extend the stream.
    function _ingestRewards(uint256 amount) internal {
        if (totalSupply() == 0) {
            pendingRewards += amount;
            emit RewardsParked(amount, pendingRewards);
            return;
        }

        uint256 toNotify = amount + pendingRewards;
        pendingRewards = 0;
        _notifyReward(toNotify);
    }

    uint256[43] private __gap;
}

