// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title TRAIDEOracle
 * @dev Price Oracle contract with Chainlink integration
 * August 2025 Standards - Professional price feeds with defensive programming
 */
contract TRAIDEOracle is Ownable, ReentrancyGuard {
    
    struct PriceFeed {
        AggregatorV3Interface aggregator;
        uint256 heartbeat; // Maximum staleness in seconds
        uint8 decimals;
        bool isActive;
    }
    
    mapping(address => PriceFeed) public priceFeeds;
    mapping(address => uint256) public manualPrices; // Fallback prices
    
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant MAX_STALENESS = 86400; // 24 hours
    
    event PriceFeedAdded(address indexed token, address indexed aggregator);
    event PriceFeedUpdated(address indexed token, address indexed aggregator);
    event ManualPriceSet(address indexed token, uint256 price);
    event PriceRequested(address indexed token, uint256 price, uint256 timestamp);
    
    error StalePriceFeed(address token);
    error InvalidPriceFeed(address token);
    error PriceNotAvailable(address token);
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev Get price for a token with defensive programming
     * @param token Token address to get price for
     * @return price Price in 18 decimals
     */
    function getPrice(address token) external view returns (uint256 price) {
        PriceFeed memory feed = priceFeeds[token];
        
        if (!feed.isActive) {
            // Fallback to manual price
            price = manualPrices[token];
            if (price == 0) revert PriceNotAvailable(token);
            return price;
        }
        
        try feed.aggregator.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check for stale data
            if (block.timestamp - updatedAt > feed.heartbeat) {
                revert StalePriceFeed(token);
            }
            
            // Check for invalid data
            if (answer <= 0 || updatedAt == 0) {
                revert InvalidPriceFeed(token);
            }
            
            // Convert to 18 decimals
            price = uint256(answer) * PRICE_PRECISION / (10 ** feed.decimals);
            
        } catch {
            // Fallback to manual price on Chainlink failure
            price = manualPrices[token];
            if (price == 0) revert PriceNotAvailable(token);
        }
    }
    
    /**
     * @dev Add new price feed
     */
    function addPriceFeed(
        address token,
        address aggregator,
        uint256 heartbeat
    ) external onlyOwner {
        require(heartbeat <= MAX_STALENESS, "Heartbeat too long");
        
        AggregatorV3Interface feed = AggregatorV3Interface(aggregator);
        uint8 decimals = feed.decimals();
        
        priceFeeds[token] = PriceFeed({
            aggregator: feed,
            heartbeat: heartbeat,
            decimals: decimals,
            isActive: true
        });
        
        emit PriceFeedAdded(token, aggregator);
    }
    
    /**
     * @dev Set manual fallback price (emergency use)
     */
    function setManualPrice(address token, uint256 price) external onlyOwner {
        manualPrices[token] = price;
        emit ManualPriceSet(token, price);
    }
    
    /**
     * @dev Deactivate price feed
     */
    function deactivatePriceFeed(address token) external onlyOwner {
        priceFeeds[token].isActive = false;
    }
}