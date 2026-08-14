// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TRAIDEStaking
 * @dev Staking contract with multiple lockup periods and APY rates
 * @notice Users can stake TRAIDE tokens for rewards with different lockup periods
 */
contract TRAIDEStaking is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public immutable traideToken; // The TRAIDE token being staked
    
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lockupPeriod; // in days
        uint256 apyRate; // in basis points (e.g., 500 for 5%)
        uint256 claimedRewards;
        bool active; // To track if stake is still active
    }

    mapping(address => StakeInfo[]) public userStakes; // User can have multiple stakes
    mapping(uint256 => uint256) public lockupToAPY; // Mapping lockup days to APY
    
    // Total staked amount for analytics
    uint256 public totalStaked;
    uint256 public totalRewardsPaid;
    
    // Reward pool for paying out staking rewards
    uint256 public rewardPool;
    
    // Constants
    uint256 public constant SECONDS_PER_YEAR = 31536000; // 365 days
    uint256 public constant BASIS_POINTS = 10000; // 100% = 10000 basis points
    uint256 public constant MIN_STAKE_AMOUNT = 100 * 10**18; // 100 TRAIDE minimum

    // Events
    event Staked(
        address indexed staker, 
        uint256 indexed stakeIndex,
        uint256 amount, 
        uint256 startTime, 
        uint256 lockupPeriod, 
        uint256 apyRate
    );
    event Unstaked(
        address indexed staker, 
        uint256 indexed stakeIndex,
        uint256 amount, 
        uint256 rewardsClaimed
    );
    event RewardsClaimed(
        address indexed staker, 
        uint256 indexed stakeIndex,
        uint256 amount
    );
    event RewardPoolFunded(uint256 amount);
    event APYUpdated(uint256 lockupDays, uint256 newAPY);

    /**
     * @dev Constructor
     * @param _traideToken Address of the TRAIDE token contract
     */
    constructor(address _traideToken) Ownable(msg.sender) {
        require(_traideToken != address(0), "Invalid TRAIDE token address");
        traideToken = IERC20(_traideToken);
        
        // Initialize default APY rates
        lockupToAPY[30] = 500;   // 5% APY for 30 days
        lockupToAPY[90] = 700;   // 7% APY for 90 days
        lockupToAPY[180] = 1000; // 10% APY for 180 days
    }

    /**
     * @dev Stake TRAIDE tokens with specified lockup period
     * @param amount Amount of TRAIDE tokens to stake
     * @param lockupDays Lockup period in days (30, 90, or 180)
     */
    function stake(uint256 amount, uint256 lockupDays) external nonReentrant whenNotPaused {
        require(amount >= MIN_STAKE_AMOUNT, "Amount below minimum stake");
        require(lockupToAPY[lockupDays] > 0, "Invalid lockup period");

        uint256 apy = lockupToAPY[lockupDays];

        // Transfer tokens from user to contract
        traideToken.safeTransferFrom(msg.sender, address(this), amount);

        // Create new stake
        userStakes[msg.sender].push(StakeInfo({
            amount: amount,
            startTime: block.timestamp,
            lockupPeriod: lockupDays,
            apyRate: apy,
            claimedRewards: 0,
            active: true
        }));

        totalStaked += amount;
        
        uint256 stakeIndex = userStakes[msg.sender].length - 1;
        emit Staked(msg.sender, stakeIndex, amount, block.timestamp, lockupDays, apy);
    }

    /**
     * @dev Calculate pending rewards for a specific stake
     * @param staker Address of the staker
     * @param stakeIndex Index of the stake
     * @return pendingRewards Amount of pending rewards
     */
    function calculatePendingRewards(address staker, uint256 stakeIndex) 
        public view returns (uint256 pendingRewards) {
        require(stakeIndex < userStakes[staker].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[staker][stakeIndex];
        
        if (!stake.active || stake.amount == 0) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - stake.startTime;
        uint256 annualReward = (stake.amount * stake.apyRate) / BASIS_POINTS;
        uint256 totalEarnedReward = (annualReward * elapsedTime) / SECONDS_PER_YEAR;

        pendingRewards = totalEarnedReward > stake.claimedRewards 
            ? totalEarnedReward - stake.claimedRewards 
            : 0;
    }

    /**
     * @dev Calculate total pending rewards for a staker across all stakes
     * @param staker Address of the staker
     * @return totalRewards Total pending rewards
     */
    function getTotalPendingRewards(address staker) external view returns (uint256 totalRewards) {
        for (uint256 i = 0; i < userStakes[staker].length; i++) {
            totalRewards += calculatePendingRewards(staker, i);
        }
    }

    /**
     * @dev Check if a stake can be unstaked (lockup period has passed)
     * @param staker Address of the staker
     * @param stakeIndex Index of the stake
     * @return canUnstake True if stake can be unstaked
     */
    function canUnstake(address staker, uint256 stakeIndex) public view returns (bool canUnstake) {
        require(stakeIndex < userStakes[staker].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[staker][stakeIndex];
        
        if (!stake.active) {
            return false;
        }
        
        return block.timestamp >= stake.startTime + (stake.lockupPeriod * 1 days);
    }

    /**
     * @dev Unstake tokens and claim all rewards
     * @param stakeIndex Index of the stake to unstake
     */
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[msg.sender][stakeIndex];
        require(stake.active, "Stake already inactive");
        require(stake.amount > 0, "No tokens staked");
        require(canUnstake(msg.sender, stakeIndex), "Lockup period not over");

        uint256 pendingRewards = calculatePendingRewards(msg.sender, stakeIndex);
        uint256 stakedAmount = stake.amount;

        // Mark stake as inactive
        stake.active = false;
        totalStaked -= stakedAmount;

        // Transfer staked amount back to user
        traideToken.safeTransfer(msg.sender, stakedAmount);

        // Transfer rewards if any and if reward pool has sufficient balance
        if (pendingRewards > 0 && rewardPool >= pendingRewards) {
            stake.claimedRewards += pendingRewards;
            totalRewardsPaid += pendingRewards;
            rewardPool -= pendingRewards;
            traideToken.safeTransfer(msg.sender, pendingRewards);
        }

        emit Unstaked(msg.sender, stakeIndex, stakedAmount, pendingRewards);
    }

    /**
     * @dev Claim rewards without unstaking
     * @param stakeIndex Index of the stake to claim rewards from
     */
    function claimRewards(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[msg.sender][stakeIndex];
        require(stake.active, "Stake is not active");

        uint256 pendingRewards = calculatePendingRewards(msg.sender, stakeIndex);
        require(pendingRewards > 0, "No pending rewards");
        require(rewardPool >= pendingRewards, "Insufficient reward pool");

        stake.claimedRewards += pendingRewards;
        totalRewardsPaid += pendingRewards;
        rewardPool -= pendingRewards;
        
        traideToken.safeTransfer(msg.sender, pendingRewards);

        emit RewardsClaimed(msg.sender, stakeIndex, pendingRewards);
    }

    /**
     * @dev Emergency unstake - allows unstaking before lockup with penalty
     * @param stakeIndex Index of the stake to emergency unstake
     */
    function emergencyUnstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < userStakes[msg.sender].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[msg.sender][stakeIndex];
        require(stake.active, "Stake already inactive");
        require(stake.amount > 0, "No tokens staked");

        uint256 stakedAmount = stake.amount;
        uint256 penalty = 0;
        
        // Apply penalty if lockup period hasn't passed (10% penalty)
        if (!canUnstake(msg.sender, stakeIndex)) {
            penalty = (stakedAmount * 1000) / BASIS_POINTS; // 10% penalty
        }

        uint256 amountToReturn = stakedAmount - penalty;

        // Mark stake as inactive
        stake.active = false;
        totalStaked -= stakedAmount;

        // Transfer remaining amount to user
        traideToken.safeTransfer(msg.sender, amountToReturn);
        
        // Penalty goes to reward pool
        if (penalty > 0) {
            rewardPool += penalty;
        }

        emit Unstaked(msg.sender, stakeIndex, amountToReturn, 0);
    }

    /**
     * @dev Fund the reward pool (only owner)
     * @param amount Amount of TRAIDE tokens to add to reward pool
     */
    function fundRewardPool(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");
        
        traideToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardPool += amount;
        
        emit RewardPoolFunded(amount);
    }

    /**
     * @dev Update APY for a lockup period (only owner)
     * @param lockupDays Lockup period in days
     * @param newAPY New APY in basis points
     */
    function updateAPY(uint256 lockupDays, uint256 newAPY) external onlyOwner {
        require(newAPY > 0 && newAPY <= 5000, "APY must be between 0.01% and 50%");
        
        lockupToAPY[lockupDays] = newAPY;
        emit APYUpdated(lockupDays, newAPY);
    }

    /**
     * @dev Get number of active stakes for a user
     * @param staker Address of the staker
     * @return count Number of active stakes
     */
    function getActiveStakesCount(address staker) external view returns (uint256 count) {
        for (uint256 i = 0; i < userStakes[staker].length; i++) {
            if (userStakes[staker][i].active) {
                count++;
            }
        }
    }

    /**
     * @dev Get total number of stakes for a user
     * @param staker Address of the staker
     * @return Number of stakes
     */
    function getNumberOfStakes(address staker) external view returns (uint256) {
        return userStakes[staker].length;
    }

    /**
     * @dev Get details of a specific stake
     * @param staker Address of the staker
     * @param stakeIndex Index of the stake
     * @return amount Staked amount
     * @return startTime Stake start time
     * @return lockupPeriod Lockup period in days
     * @return apyRate APY rate in basis points
     * @return claimedRewards Already claimed rewards
     * @return active Whether stake is active
     */
    function getStakeInfo(address staker, uint256 stakeIndex) 
        external view returns (
            uint256 amount, 
            uint256 startTime, 
            uint256 lockupPeriod, 
            uint256 apyRate, 
            uint256 claimedRewards,
            bool active
        ) {
        require(stakeIndex < userStakes[staker].length, "Invalid stake index");
        
        StakeInfo storage stake = userStakes[staker][stakeIndex];
        return (
            stake.amount, 
            stake.startTime, 
            stake.lockupPeriod, 
            stake.apyRate, 
            stake.claimedRewards,
            stake.active
        );
    }

    /**
     * @dev Get contract statistics
     * @return totalStaked_ Total amount staked
     * @return totalRewardsPaid_ Total rewards paid out
     * @return rewardPool_ Current reward pool balance
     */
    function getContractStats() external view returns (
        uint256 totalStaked_, 
        uint256 totalRewardsPaid_, 
        uint256 rewardPool_
    ) {
        return (totalStaked, totalRewardsPaid, rewardPool);
    }

    /**
     * @dev Pause contract (emergency function)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency token recovery (only owner)
     * @param token Token address to recover
     * @param amount Amount to recover
     */
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(traideToken), "Cannot recover TRAIDE tokens");
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Get contract version
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
