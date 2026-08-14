// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TRAIDEFeeDistribution
 * @dev Professional fee distribution for LP rewards and protocol revenue
 * August 2025 Standards - Automated fee collection and distribution
 */
contract TRAIDEFeeDistribution is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;
    
    struct RewardPool {
        IERC20 token;
        uint256 totalRewards;
        uint256 rewardPerTokenStored;
        uint256 lastUpdateTime;
        mapping(address => uint256) userRewardPerTokenPaid;
        mapping(address => uint256) rewards;
        mapping(address => uint256) balances;
        uint256 totalSupply;
    }
    
    mapping(address => RewardPool) public rewardPools;
    address[] public poolTokens;
    
    // Fee distribution configuration
    uint256 public lpRewardRate = 7000; // 70% to LP providers
    uint256 public protocolFeeRate = 2000; // 20% to protocol
    uint256 public stakingRewardRate = 1000; // 10% to stakers
    uint256 public constant RATE_PRECISION = 10000;
    
    address public protocolTreasury;
    address public stakingContract;
    
    event RewardAdded(address indexed token, uint256 reward);
    event RewardPaid(address indexed user, address indexed token, uint256 reward);
    event Staked(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event FeeDistributed(address indexed token, uint256 lpAmount, uint256 protocolAmount, uint256 stakingAmount);
    
    constructor(
        address _protocolTreasury,
        address _stakingContract
    ) Ownable(msg.sender) {
        protocolTreasury = _protocolTreasury;
        stakingContract = _stakingContract;
    }
    
    modifier updateReward(address token, address account) {
        RewardPool storage pool = rewardPools[token];
        pool.rewardPerTokenStored = rewardPerToken(token);
        pool.lastUpdateTime = block.timestamp;
        
        if (account != address(0)) {
            pool.rewards[account] = earned(token, account);
            pool.userRewardPerTokenPaid[account] = pool.rewardPerTokenStored;
        }
        _;
    }
    
    /**
     * @dev Calculate reward per token
     */
    function rewardPerToken(address token) public view returns (uint256) {
        RewardPool storage pool = rewardPools[token];
        if (pool.totalSupply == 0) {
            return pool.rewardPerTokenStored;
        }
        
        return pool.rewardPerTokenStored + 
            ((block.timestamp - pool.lastUpdateTime) * 1e18 / pool.totalSupply);
    }
    
    /**
     * @dev Calculate earned rewards for user
     */
    function earned(address token, address account) public view returns (uint256) {
        RewardPool storage pool = rewardPools[token];
        return pool.balances[account] * 
            (rewardPerToken(token) - pool.userRewardPerTokenPaid[account]) / 1e18 + 
            pool.rewards[account];
    }
    
    /**
     * @dev Stake LP tokens to earn rewards
     */
    function stake(address token, uint256 amount) 
        external 
        nonReentrant 
        updateReward(token, msg.sender) 
    {
        require(amount > 0, "Cannot stake 0");
        
        RewardPool storage pool = rewardPools[token];
        pool.totalSupply += amount;
        pool.balances[msg.sender] += amount;
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, token, amount);
    }
    
    /**
     * @dev Withdraw LP tokens
     */
    function withdraw(address token, uint256 amount) 
        external 
        nonReentrant 
        updateReward(token, msg.sender) 
    {
        require(amount > 0, "Cannot withdraw 0");
        
        RewardPool storage pool = rewardPools[token];
        pool.totalSupply -= amount;
        pool.balances[msg.sender] -= amount;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }
    
    /**
     * @dev Claim rewards
     */
    function getReward(address token) 
        external 
        nonReentrant 
        updateReward(token, msg.sender) 
    {
        RewardPool storage pool = rewardPools[token];
        uint256 reward = pool.rewards[msg.sender];
        
        if (reward > 0) {
            pool.rewards[msg.sender] = 0;
            pool.token.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, token, reward);
        }
    }
    
    /**
     * @dev Distribute collected fees according to rates
     */
    function distributeFees(address token, uint256 totalFees) 
        external 
        nonReentrant 
        updateReward(token, address(0)) 
    {
        require(msg.sender == owner() || msg.sender == address(this), "Unauthorized");
        
        uint256 lpAmount = totalFees * lpRewardRate / RATE_PRECISION;
        uint256 protocolAmount = totalFees * protocolFeeRate / RATE_PRECISION;
        uint256 stakingAmount = totalFees * stakingRewardRate / RATE_PRECISION;
        
        RewardPool storage pool = rewardPools[token];
        
        // Add to LP reward pool
        if (lpAmount > 0) {
            pool.totalRewards += lpAmount;
        }
        
        // Send to protocol treasury
        if (protocolAmount > 0) {
            IERC20(token).safeTransfer(protocolTreasury, protocolAmount);
        }
        
        // Send to staking contract
        if (stakingAmount > 0) {
            IERC20(token).safeTransfer(stakingContract, stakingAmount);
        }
        
        emit FeeDistributed(token, lpAmount, protocolAmount, stakingAmount);
    }
    
    /**
     * @dev Add new reward pool
     */
    function addRewardPool(address token) external onlyOwner {
        RewardPool storage pool = rewardPools[token];
        pool.token = IERC20(token);
        pool.lastUpdateTime = block.timestamp;
        poolTokens.push(token);
    }
    
    /**
     * @dev Update fee distribution rates
     */
    function updateFeeRates(
        uint256 _lpRate,
        uint256 _protocolRate,
        uint256 _stakingRate
    ) external onlyOwner {
        require(_lpRate + _protocolRate + _stakingRate == RATE_PRECISION, "Invalid rates");
        lpRewardRate = _lpRate;
        protocolFeeRate = _protocolRate;
        stakingRewardRate = _stakingRate;
    }
}