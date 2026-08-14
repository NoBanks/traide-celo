// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./TRAIDEToken.sol";

/**
 * @title TRAIDEAMM
 * @dev Automated Market Maker with constant product formula (x * y = k)
 * @notice Core AMM contract for TRAIDE DeFi platform with integrated fee discounts
 */
contract TRAIDEAMM is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Core AMM state
    mapping(address => mapping(address => uint256)) public reserves;
    mapping(address => mapping(address => bool)) public pairExists;
    mapping(address => mapping(address => uint256)) public totalShares;
    mapping(address => mapping(address => mapping(address => uint256))) public userShares;
    
    // Fee configuration
    uint256 public constant BASE_FEE_BPS = 30;  // 0.3% base fee
    uint256 public constant PROTOCOL_FEE_BPS = 5; // 0.05% protocol fee (from the 0.3%)
    uint256 public constant MAX_FEE_BPS = 10000; // 100% in basis points
    
    // TRAIDE token for fee discounts
    TRAIDEToken public immutable traideToken;
    address public feeRecipient;
    
    // Minimum liquidity to prevent division by zero
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Events
    event PairCreated(address indexed tokenA, address indexed tokenB);
    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA, 
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 shares
    );
    event LiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB, 
        uint256 amountA,
        uint256 amountB,
        uint256 shares
    );
    event TokensSwapped(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    
    /**
     * @dev Constructor
     * @param _traideToken Address of TRAIDE token for fee discounts
     * @param _feeRecipient Address to receive protocol fees
     */
    constructor(address _traideToken, address _feeRecipient) Ownable(msg.sender) {
        require(_traideToken != address(0), "Invalid TRAIDE token address");
        require(_feeRecipient != address(0), "Invalid fee recipient address");
        
        traideToken = TRAIDEToken(_traideToken);
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @dev Create a new trading pair
     * @param tokenA First token address
     * @param tokenB Second token address
     */
    function createPair(address tokenA, address tokenB) external {
        require(tokenA != tokenB, "Identical tokens");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        require(!pairExists[tokenA][tokenB], "Pair already exists");
        
        pairExists[tokenA][tokenB] = true;
        pairExists[tokenB][tokenA] = true;
        
        emit PairCreated(tokenA, tokenB);
    }
    
    /**
     * @dev Add liquidity to a trading pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountA Amount of tokenA to add
     * @param amountB Amount of tokenB to add
     * @param minAmountA Minimum amount of tokenA (slippage protection)
     * @param minAmountB Minimum amount of tokenB (slippage protection)
     * @return shares Number of LP shares minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 minAmountA,
        uint256 minAmountB
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        require(amountA > 0 && amountB > 0, "Invalid amounts");
        require(pairExists[tokenA][tokenB], "Pair does not exist");
        
        uint256 reserveA = reserves[tokenA][tokenB];
        uint256 reserveB = reserves[tokenB][tokenA];
        
        // Calculate optimal amounts
        if (reserveA == 0 && reserveB == 0) {
            // First liquidity provision
            require(amountA >= minAmountA && amountB >= minAmountB, "Insufficient amounts");
            shares = _sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            totalShares[tokenA][tokenB] = shares + MINIMUM_LIQUIDITY;
        } else {
            // Subsequent liquidity provision - maintain ratio
            uint256 optimalAmountB = (amountA * reserveB) / reserveA;
            uint256 optimalAmountA = (amountB * reserveA) / reserveB;
            
            if (optimalAmountB <= amountB) {
                require(optimalAmountB >= minAmountB, "Insufficient tokenB amount");
                amountB = optimalAmountB;
            } else {
                require(optimalAmountA >= minAmountA, "Insufficient tokenA amount");
                amountA = optimalAmountA;
            }
            
            shares = _min(
                (amountA * totalShares[tokenA][tokenB]) / reserveA,
                (amountB * totalShares[tokenA][tokenB]) / reserveB
            );
            totalShares[tokenA][tokenB] += shares;
        }
        
        require(shares > 0, "Insufficient liquidity minted");
        
        // Transfer tokens
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
        
        // Update reserves
        reserves[tokenA][tokenB] += amountA;
        reserves[tokenB][tokenA] += amountB;
        
        // Update user shares
        userShares[tokenA][tokenB][msg.sender] += shares;
        
        emit LiquidityAdded(msg.sender, tokenA, tokenB, amountA, amountB, shares);
    }
    
    /**
     * @dev Remove liquidity from a trading pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param shares Number of LP shares to burn
     * @param minAmountA Minimum amount of tokenA to receive
     * @param minAmountB Minimum amount of tokenB to receive
     * @return amountA Amount of tokenA received
     * @return amountB Amount of tokenB received
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 shares,
        uint256 minAmountA,
        uint256 minAmountB
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(shares > 0, "Invalid shares amount");
        require(userShares[tokenA][tokenB][msg.sender] >= shares, "Insufficient shares");
        require(pairExists[tokenA][tokenB], "Pair does not exist");
        
        uint256 reserveA = reserves[tokenA][tokenB];
        uint256 reserveB = reserves[tokenB][tokenA];
        uint256 totalSupply = totalShares[tokenA][tokenB];
        
        // Calculate amounts to return
        amountA = (shares * reserveA) / totalSupply;
        amountB = (shares * reserveB) / totalSupply;
        
        require(amountA >= minAmountA && amountB >= minAmountB, "Insufficient output amounts");
        
        // Update state
        userShares[tokenA][tokenB][msg.sender] -= shares;
        totalShares[tokenA][tokenB] -= shares;
        reserves[tokenA][tokenB] -= amountA;
        reserves[tokenB][tokenA] -= amountB;
        
        // Transfer tokens
        IERC20(tokenA).safeTransfer(msg.sender, amountA);
        IERC20(tokenB).safeTransfer(msg.sender, amountB);
        
        emit LiquidityRemoved(msg.sender, tokenA, tokenB, amountA, amountB, shares);
    }
    
    /**
     * @dev Swap tokens using constant product formula
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens (slippage protection)
     * @return amountOut Amount of output tokens received
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid input amount");
        require(tokenIn != tokenOut, "Identical tokens");
        require(pairExists[tokenIn][tokenOut], "Pair does not exist");
        
        uint256 reserveIn = reserves[tokenIn][tokenOut];
        uint256 reserveOut = reserves[tokenOut][tokenIn];
        
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        // Calculate fee with TRAIDE discount
        uint256 feeDiscount = traideToken.getFeeDiscount(msg.sender);
        uint256 effectiveFee = BASE_FEE_BPS - (BASE_FEE_BPS * feeDiscount / 100);
        
        // Calculate amounts
        uint256 amountInWithFee = amountIn * (MAX_FEE_BPS - effectiveFee) / MAX_FEE_BPS;
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
        
        require(amountOut >= minAmountOut, "Insufficient output amount");
        require(amountOut < reserveOut, "Insufficient liquidity");
        
        // Calculate protocol fee
        uint256 protocolFeeAmount = (amountIn * PROTOCOL_FEE_BPS) / MAX_FEE_BPS;
        
        // Transfer tokens
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        
        // Transfer protocol fee
        if (protocolFeeAmount > 0) {
            IERC20(tokenIn).safeTransfer(feeRecipient, protocolFeeAmount);
        }
        
        // Update reserves
        reserves[tokenIn][tokenOut] += amountIn - protocolFeeAmount;
        reserves[tokenOut][tokenIn] -= amountOut;
        
        emit TokensSwapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, effectiveFee);
    }
    
    /**
     * @dev Get swap quote
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param user User address for fee discount calculation
     * @return amountOut Expected output amount
     * @return feeAmount Fee amount
     */
    function getSwapQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address user
    ) external view returns (uint256 amountOut, uint256 feeAmount) {
        require(pairExists[tokenIn][tokenOut], "Pair does not exist");
        
        uint256 reserveIn = reserves[tokenIn][tokenOut];
        uint256 reserveOut = reserves[tokenOut][tokenIn];
        
        if (reserveIn == 0 || reserveOut == 0) {
            return (0, 0);
        }
        
        // Calculate fee with TRAIDE discount
        uint256 feeDiscount = traideToken.getFeeDiscount(user);
        uint256 effectiveFee = BASE_FEE_BPS - (BASE_FEE_BPS * feeDiscount / 100);
        
        feeAmount = (amountIn * effectiveFee) / MAX_FEE_BPS;
        uint256 amountInWithFee = amountIn - feeAmount;
        
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
    }
    
    /**
     * @dev Get pair reserves
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return reserveA Reserve of tokenA
     * @return reserveB Reserve of tokenB
     */
    function getReserves(address tokenA, address tokenB) 
        external view returns (uint256 reserveA, uint256 reserveB) {
        reserveA = reserves[tokenA][tokenB];
        reserveB = reserves[tokenB][tokenA];
    }
    
    /**
     * @dev Get user's LP shares
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param user User address
     * @return shares Number of LP shares owned
     */
    function getUserShares(address tokenA, address tokenB, address user) 
        external view returns (uint256 shares) {
        return userShares[tokenA][tokenB][user];
    }
    
    /**
     * @dev Update fee recipient (only owner)
     * @param newFeeRecipient New fee recipient address
     */
    function updateFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), "Invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(oldRecipient, newFeeRecipient);
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
     * @dev Emergency token recovery
     * @param token Token address to recover
     * @param amount Amount to recover
     */
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    // Internal helper functions
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    
    /**
     * @dev Get contract version
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
