// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./TRAIDEPair.sol";

/**
 * @title TRAIDEFactory
 * @dev Factory contract for creating and managing TRAIDE trading pairs
 * @notice Creates deterministic pair contracts for token trading
 */
contract TRAIDEFactory is Ownable, ReentrancyGuard, Pausable {
    
    // Core factory state
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    
    // Fee configuration
    address public feeTo;
    address public feeToSetter;
    
    // Protocol integration
    address public immutable traideToken;
    address public immutable traideAMM;
    
    // Constants
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(TRAIDEPair).creationCode));
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    
    // Events
    event PairCreated(
        address indexed token0, 
        address indexed token1, 
        address pair, 
        uint256 allPairsLength
    );
    event FeeToUpdated(address indexed oldFeeTo, address indexed newFeeTo);
    event FeeToSetterUpdated(address indexed oldFeeToSetter, address indexed newFeeToSetter);
    event FactoryPaused();
    event FactoryUnpaused();
    
    /**
     * @dev Constructor
     * @param _feeToSetter Address that can update fee recipient
     * @param _traideToken TRAIDE token address for ecosystem integration
     * @param _traideAMM TRAIDE AMM address for routing
     */
    constructor(
        address _feeToSetter,
        address _traideToken,
        address _traideAMM
    ) Ownable(msg.sender) {
        require(_feeToSetter != address(0), "Invalid fee setter");
        require(_traideToken != address(0), "Invalid TRAIDE token");
        require(_traideAMM != address(0), "Invalid TRAIDE AMM");
        
        feeToSetter = _feeToSetter;
        traideToken = _traideToken;
        traideAMM = _traideAMM;
    }
    
    /**
     * @dev Get total number of pairs created
     * @return Number of pairs
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
    
    /**
     * @dev Create a new trading pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair Address of created pair contract
     */
    function createPair(address tokenA, address tokenB) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (address pair) {
        require(tokenA != tokenB, "Identical addresses");
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        
        // Sort tokens to ensure deterministic pair addresses
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(getPair[token0][token1] == address(0), "Pair exists");
        
        // Create pair contract with CREATE2 for deterministic addresses
        bytes memory bytecode = type(TRAIDEPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        require(pair != address(0), "Pair creation failed");
        
        // Initialize the pair
        TRAIDEPair(pair).initialize(token0, token1, traideToken, traideAMM);
        
        // Update mappings
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
    
    /**
     * @dev Set fee recipient address (only feeToSetter)
     * @param _feeTo New fee recipient address
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "Forbidden");
        address oldFeeTo = feeTo;
        feeTo = _feeTo;
        emit FeeToUpdated(oldFeeTo, _feeTo);
    }
    
    /**
     * @dev Set fee setter address (only feeToSetter)
     * @param _feeToSetter New fee setter address
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "Forbidden");
        require(_feeToSetter != address(0), "Invalid fee setter");
        address oldFeeToSetter = feeToSetter;
        feeToSetter = _feeToSetter;
        emit FeeToSetterUpdated(oldFeeToSetter, _feeToSetter);
    }
    
    /**
     * @dev Get pair address for two tokens (view function)
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return pair Pair address (0x0 if doesn't exist)
     */
    function getPairAddress(address tokenA, address tokenB) external view returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return getPair[token0][token1];
    }
    
    /**
     * @dev Check if pair exists for two tokens
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return exists True if pair exists
     */
    function pairExists(address tokenA, address tokenB) external view returns (bool exists) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return getPair[token0][token1] != address(0);
    }
    
    /**
     * @dev Get all pair addresses
     * @return Array of all pair addresses
     */
    function getAllPairs() external view returns (address[] memory) {
        return allPairs;
    }
    
    /**
     * @dev Get pairs created between two indices
     * @param start Start index
     * @param end End index
     * @return pairs Array of pair addresses
     */
    function getPairs(uint256 start, uint256 end) external view returns (address[] memory pairs) {
        require(start <= end && end < allPairs.length, "Invalid indices");
        
        pairs = new address[](end - start + 1);
        for (uint256 i = start; i <= end; i++) {
            pairs[i - start] = allPairs[i];
        }
    }
    
    /**
     * @dev Get factory statistics
     * @return totalPairs Total number of pairs created
     * @return feeTo_ Current fee recipient
     * @return feeToSetter_ Current fee setter
     */
    function getFactoryStats() external view returns (
        uint256 totalPairs,
        address feeTo_,
        address feeToSetter_
    ) {
        return (allPairs.length, feeTo, feeToSetter);
    }
    
    /**
     * @dev Pause factory (emergency function)
     */
    function pause() external onlyOwner {
        _pause();
        emit FactoryPaused();
    }
    
    /**
     * @dev Unpause factory
     */
    function unpause() external onlyOwner {
        _unpause();
        emit FactoryUnpaused();
    }
    
    /**
     * @dev Emergency function to pause all pairs
     * @param pairs Array of pair addresses to pause
     */
    function emergencyPausePairs(address[] calldata pairs) external onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i] != address(0)) {
                try TRAIDEPair(pairs[i]).pause() {} catch {}
            }
        }
    }
    
    /**
     * @dev Emergency function to unpause all pairs
     * @param pairs Array of pair addresses to unpause
     */
    function emergencyUnpausePairs(address[] calldata pairs) external onlyOwner {
        for (uint256 i = 0; i < pairs.length; i++) {
            if (pairs[i] != address(0)) {
                try TRAIDEPair(pairs[i]).unpause() {} catch {}
            }
        }
    }
    
    /**
     * @dev Get contract version
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
    
    /**
     * @dev Get factory configuration
     * @return traideToken_ TRAIDE token address
     * @return traideAMM_ TRAIDE AMM address
     * @return initCodeHash Init code hash for pair creation
     */
    function getFactoryConfig() external view returns (
        address traideToken_,
        address traideAMM_,
        bytes32 initCodeHash
    ) {
        return (traideToken, traideAMM, INIT_CODE_PAIR_HASH);
    }
}