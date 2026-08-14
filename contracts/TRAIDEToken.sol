// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TRAIDEToken
 * @dev Enhanced ERC20 token with governance features for TRAIDE DeFi platform
 * @notice This is the native token of the TRAIDE ecosystem
 */
contract TRAIDEToken is ERC20, ERC20Burnable, ERC20Pausable, Ownable, ReentrancyGuard {
    
    // Maximum supply: 1 billion tokens
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18;
    
    // Fee discount tiers based on TRAIDE holdings
    uint256 public constant TIER_1_THRESHOLD = 1_000 * 10**18;    // 1K TRAIDE = 5% discount
    uint256 public constant TIER_2_THRESHOLD = 10_000 * 10**18;   // 10K TRAIDE = 10% discount  
    uint256 public constant TIER_3_THRESHOLD = 100_000 * 10**18;  // 100K TRAIDE = 20% discount
    
    // Events
    event TokensMinted(address indexed to, uint256 amount);
    event FeeDiscountApplied(address indexed user, uint256 discountPercent);
    
    /**
     * @dev Constructor that mints initial supply to deployer
     * @param initialSupply The initial amount of tokens to mint
     */
    constructor(uint256 initialSupply) ERC20("TRAIDE Token", "TRAIDE") Ownable(msg.sender) {
        require(initialSupply <= MAX_SUPPLY, "Initial supply exceeds maximum");
        _mint(msg.sender, initialSupply);
        emit TokensMinted(msg.sender, initialSupply);
    }
    
    /**
     * @dev Mint new tokens (only owner can mint)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "Minting would exceed max supply");
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }
    
    /**
     * @dev Pause token transfers (emergency function)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Get fee discount percentage based on user's TRAIDE balance
     * @param user Address to check discount for
     * @return discountPercent Fee discount percentage (0-20)
     */
    function getFeeDiscount(address user) external view returns (uint256 discountPercent) {
        uint256 balance = balanceOf(user);
        
        if (balance >= TIER_3_THRESHOLD) {
            return 20; // 20% discount
        } else if (balance >= TIER_2_THRESHOLD) {
            return 10; // 10% discount
        } else if (balance >= TIER_1_THRESHOLD) {
            return 5;  // 5% discount
        } else {
            return 0;  // No discount
        }
    }
    
    /**
     * @dev Check if user qualifies for any fee discount
     * @param user Address to check
     * @return hasDiscount True if user has any discount tier
     */
    function hasAnyDiscount(address user) external view returns (bool hasDiscount) {
        return balanceOf(user) >= TIER_1_THRESHOLD;
    }
    
    /**
     * @dev Get user's discount tier (0 = no discount, 1-3 = discount tiers)
     * @param user Address to check
     * @return tier Discount tier (0-3)
     */
    function getDiscountTier(address user) external view returns (uint256 tier) {
        uint256 balance = balanceOf(user);
        
        if (balance >= TIER_3_THRESHOLD) {
            return 3;
        } else if (balance >= TIER_2_THRESHOLD) {
            return 2;
        } else if (balance >= TIER_1_THRESHOLD) {
            return 1;
        } else {
            return 0;
        }
    }
    
    /**
     * @dev Override required by Solidity for multiple inheritance
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
    
    /**
     * @dev Emergency function to recover accidentally sent tokens
     * @param token Address of token to recover
     * @param amount Amount to recover
     */
    function emergencyRecoverToken(address token, uint256 amount) external onlyOwner nonReentrant {
        require(token != address(this), "Cannot recover TRAIDE tokens");
        IERC20(token).transfer(owner(), amount);
    }
    
    /**
     * @dev Get contract version for upgrades
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
