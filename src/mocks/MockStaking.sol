// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal mainnet test stub that mirrors the four user-facing entry-points
///         of Staking. Balances and rewards are tracked in plain mappings;
///         no ERC20, no rewards math — just enough to exercise callsites.
contract MockStaking {
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public pendingRewards;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event Exited(address indexed user, uint256 staked, uint256 rewards);

    receive() external payable {}

    function stake() external payable {
        require(msg.value > 0, "zero amount");
        balanceOf[msg.sender] += msg.value;
        emit Staked(msg.sender, msg.value);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external returns (uint256 amount) {
        amount = pendingRewards[msg.sender];
        require(amount > 0, "nothing to claim");
        pendingRewards[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "transfer failed");
        emit RewardsClaimed(msg.sender, amount);
    }

    function exit() external returns (uint256 staked, uint256 rewards) {
        staked = balanceOf[msg.sender];
        rewards = pendingRewards[msg.sender];
        require(staked > 0 || rewards > 0, "nothing to exit");
        balanceOf[msg.sender] = 0;
        pendingRewards[msg.sender] = 0;
        uint256 total = staked + rewards;
        (bool ok,) = payable(msg.sender).call{value: total}("");
        require(ok, "transfer failed");
        emit Exited(msg.sender, staked, rewards);
    }

    /// @dev Seed rewards for a user so claimRewards/exit can be tested.
    function seedRewards(address user) external payable {
        require(msg.value > 0, "zero amount");
        pendingRewards[user] += msg.value;
    }
}
