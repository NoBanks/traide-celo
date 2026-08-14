// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./TRAIDEToken.sol";

/**
 * @title TRAIDEPair
 * @dev Individual trading pair contract for TRAIDE DEX
 * @notice ERC20 LP token with DEX functionality and fee discounts
 */
contract TRAIDEPair is ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Pair tokens
    address public token0;
    address public token1;
    
    // Reserves
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    // Price cumulative for TWAP oracle
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    
    // Factory and protocol addresses
    address public factory;
    TRAIDEToken public traideToken;
    address public traideAMM;
    
    // Fee configuration
    uint256 public constant BASE_FEE = 30; // 0.3% base fee in basis points
    uint256 public constant PROTOCOL_FEE = 5; // 0.05% protocol fee
    uint256 public constant BASIS_POINTS = 10000;
    
    // Minimum liquidity lock
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Events
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    
    // Modifiers
    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }
    
    /**
     * @dev Constructor - creates LP token
     */
    constructor() ERC20("TRAIDE LP Token", "TRAIDE-LP") {
        factory = msg.sender;
    }
    
    /**
     * @dev Initialize pair (called by factory)
     * @param _token0 First token address (sorted)
     * @param _token1 Second token address (sorted)
     * @param _traideToken TRAIDE token for fee discounts
     * @param _traideAMM TRAIDE AMM for routing
     */
    function initialize(
        address _token0,
        address _token1,
        address _traideToken,
        address _traideAMM
    ) external onlyFactory {
        require(_token0 != address(0) && _token1 != address(0), "Invalid tokens");
        require(_traideToken != address(0) && _traideAMM != address(0), "Invalid protocol addresses");
        
        token0 = _token0;
        token1 = _token1;
        traideToken = TRAIDEToken(_traideToken);
        traideAMM = _traideAMM;
    }
    
    /**
     * @dev Get current reserves
     * @return _reserve0 Reserve of token0
     * @return _reserve1 Reserve of token1
     * @return _blockTimestampLast Last update timestamp
     */
    function getReserves() public view returns (
        uint112 _reserve0,
        uint112 _reserve1,
        uint32 _blockTimestampLast
    ) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    
    /**
     * @dev Add liquidity to the pair
     * @param to Address to receive LP tokens
     * @return liquidity Amount of LP tokens minted
     */
    function mint(address to) external nonReentrant whenNotPaused returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;
        
        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            // First liquidity provision
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock minimum liquidity
        } else {
            // Subsequent liquidity provision
            liquidity = _min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }
        
        require(liquidity > 0, "Insufficient liquidity minted");
        _mint(to, liquidity);
        
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }
    
    /**
     * @dev Remove liquidity from the pair
     * @param to Address to receive underlying tokens
     * @return amount0 Amount of token0 returned
     * @return amount1 Amount of token1 returned
     */
    function burn(address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        
        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        
        require(amount0 > 0 && amount1 > 0, "Insufficient liquidity burned");
        
        _burn(address(this), liquidity);
        IERC20(_token0).safeTransfer(to, amount0);
        IERC20(_token1).safeTransfer(to, amount1);
        
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }
    
    /**
     * @dev Swap tokens with fee discount support
     * @param amount0Out Amount of token0 to output
     * @param amount1Out Amount of token1 to output  
     * @param to Address to receive output tokens
     * @param data Callback data (unused)
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external nonReentrant whenNotPaused {
        require(amount0Out > 0 || amount1Out > 0, "Insufficient output amount");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "Insufficient liquidity");
        
        uint256 balance0;
        uint256 balance1;
        
        {
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "Invalid to");
            
            if (amount0Out > 0) IERC20(_token0).safeTransfer(to, amount0Out);
            if (amount1Out > 0) IERC20(_token1).safeTransfer(to, amount1Out);
            
            if (data.length > 0) {
                // Flash loan callback (if needed)
                // IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            }
            
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "Insufficient input amount");
        
        {
            // Calculate fee with TRAIDE discount
            uint256 feeDiscount = address(traideToken) != address(0) ? 
                traideToken.getFeeDiscount(msg.sender) : 0;
            uint256 effectiveFee = BASE_FEE - (BASE_FEE * feeDiscount / 100);
            
            uint256 balance0Adjusted = balance0 * BASIS_POINTS - amount0In * effectiveFee;
            uint256 balance1Adjusted = balance1 * BASIS_POINTS - amount1In * effectiveFee;
            
            require(
                balance0Adjusted * balance1Adjusted >= 
                uint256(_reserve0) * _reserve1 * (BASIS_POINTS ** 2),
                "K"
            );
        }
        
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }
    
    /**
     * @dev Force balances to match reserves (recovery function)
     * @param to Address to send excess tokens to
     */
    function skim(address to) external nonReentrant {
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        
        if (balance0 > reserve0) {
            IERC20(_token0).safeTransfer(to, balance0 - reserve0);
        }
        if (balance1 > reserve1) {
            IERC20(_token1).safeTransfer(to, balance1 - reserve1);
        }
    }
    
    /**
     * @dev Force reserves to match balances
     */
    function sync() external nonReentrant {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, reserve0, reserve1);
    }
    
    /**
     * @dev Get swap quote with fee discount
     * @param amountIn Input amount
     * @param tokenIn Input token address
     * @param user User address for fee discount
     * @return amountOut Expected output amount
     */
    function getSwapQuote(
        uint256 amountIn,
        address tokenIn,
        address user
    ) external view returns (uint256 amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "Invalid token");
        require(amountIn > 0, "Insufficient input amount");
        
        (uint112 reserveIn, uint112 reserveOut) = tokenIn == token0 ? 
            (reserve0, reserve1) : (reserve1, reserve0);
            
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");
        
        // Calculate fee with TRAIDE discount
        uint256 feeDiscount = address(traideToken) != address(0) ? 
            traideToken.getFeeDiscount(user) : 0;
        uint256 effectiveFee = BASE_FEE - (BASE_FEE * feeDiscount / 100);
        
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - effectiveFee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        
        amountOut = numerator / denominator;
    }
    
    /**
     * @dev Pause pair trading (emergency function)
     */
    function pause() external {
        require(msg.sender == factory, "Only factory");
        _pause();
    }
    
    /**
     * @dev Unpause pair trading
     */
    function unpause() external {
        require(msg.sender == factory, "Only factory");
        _unpause();
    }
    
    /**
     * @dev Update reserves and price accumulators
     */
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "Overflow");
        
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // Update price accumulators for TWAP oracle
            price0CumulativeLast += uint256(_reserve1) * timeElapsed / _reserve0;
            price1CumulativeLast += uint256(_reserve0) * timeElapsed / _reserve1;
        }
        
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        
        emit Sync(reserve0, reserve1);
    }
    
    /**
     * @dev Square root function for initial liquidity calculation
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
    
    /**
     * @dev Minimum of two numbers
     */
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