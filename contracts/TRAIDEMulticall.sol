// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title TRAIDEMulticall
 * @dev Gas-optimized batch transaction execution for TRAIDE ecosystem
 * August 2025 Standards - OpenZeppelin Multicall with TRAIDE-specific optimizations
 */
contract TRAIDEMulticall is Multicall, Ownable, ReentrancyGuard {
    
    struct BatchCall {
        address target;
        bytes callData;
        uint256 value;
    }
    
    mapping(address => bool) public authorizedCallers;
    uint256 public maxBatchSize = 50;
    
    event BatchExecuted(address indexed caller, uint256 callCount, bool success);
    event AuthorizedCallerAdded(address indexed caller);
    event AuthorizedCallerRemoved(address indexed caller);
    event MaxBatchSizeUpdated(uint256 newSize);
    
    error UnauthorizedCaller();
    error BatchSizeExceeded();
    error BatchExecutionFailed(uint256 index);
    error InsufficientValue();
    
    constructor() Ownable(msg.sender) {}
    
    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    /**
     * @dev Execute multiple calls with different targets (batch transactions)
     * @param calls Array of calls to execute
     * @return results Array of return data from each call
     */
    function batchCall(BatchCall[] calldata calls) 
        external 
        payable 
        nonReentrant 
        onlyAuthorized 
        returns (bytes[] memory results) 
    {
        if (calls.length > maxBatchSize) revert BatchSizeExceeded();
        
        uint256 totalValue = 0;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }
        
        if (msg.value < totalValue) revert InsufficientValue();
        
        results = new bytes[](calls.length);
        bool allSuccessful = true;
        
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call{value: calls[i].value}(
                calls[i].callData
            );
            
            if (!success) {
                allSuccessful = false;
                // Store error data but continue execution
                results[i] = result;
            } else {
                results[i] = result;
            }
        }
        
        emit BatchExecuted(msg.sender, calls.length, allSuccessful);
        return results;
    }
    
    /**
     * @dev Execute multiple calls on this contract (inherited from OpenZeppelin)
     * Optimized for TRAIDE ecosystem internal calls
     */
    function multicall(bytes[] calldata data) 
        public 
        virtual
        override 
        nonReentrant 
        returns (bytes[] memory results) 
    {
        if (data.length > maxBatchSize) revert BatchSizeExceeded();
        
        // Direct implementation instead of super call
        bytes memory context = msg.sender == _msgSender()
            ? new bytes(0)
            : msg.data[msg.data.length - _contextSuffixLength():];

        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            results[i] = Address.functionDelegateCall(address(this), bytes.concat(data[i], context));
        }
        return results;
    }
    
    /**
     * @dev Aggregate multiple view calls efficiently
     * @param calls Array of call data for view functions
     * @return blockNumber Current block number
     * @return results Array of return data
     */
    function aggregate(bytes[] calldata calls) 
        external 
        view 
        returns (uint256 blockNumber, bytes[] memory results) 
    {
        blockNumber = block.number;
        results = new bytes[](calls.length);
        
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).staticcall(calls[i]);
            require(success, "Multicall: call failed");
            results[i] = result;
        }
    }
    
    /**
     * @dev Aggregate calls with failure handling
     * @param calls Array of call data
     * @return blockNumber Current block number
     * @return successes Array of success flags
     * @return results Array of return data
     */
    function tryAggregate(bytes[] calldata calls) 
        external 
        view 
        returns (
            uint256 blockNumber,
            bool[] memory successes,
            bytes[] memory results
        ) 
    {
        blockNumber = block.number;
        successes = new bool[](calls.length);
        results = new bytes[](calls.length);
        
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).staticcall(calls[i]);
            successes[i] = success;
            results[i] = result;
        }
    }
    
    /**
     * @dev Get ETH balance for multiple addresses
     * @param addresses Array of addresses to check
     * @return balances Array of ETH balances
     */
    function getEthBalances(address[] calldata addresses) 
        external 
        view 
        returns (uint256[] memory balances) 
    {
        balances = new uint256[](addresses.length);
        for (uint256 i = 0; i < addresses.length; i++) {
            balances[i] = addresses[i].balance;
        }
    }
    
    /**
     * @dev Add authorized caller
     */
    function addAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }
    
    /**
     * @dev Remove authorized caller
     */
    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }
    
    /**
     * @dev Update maximum batch size
     */
    function setMaxBatchSize(uint256 _maxBatchSize) external onlyOwner {
        maxBatchSize = _maxBatchSize;
        emit MaxBatchSizeUpdated(_maxBatchSize);
    }
    
    /**
     * @dev Emergency withdraw ETH
     */
    function emergencyWithdraw() external onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
    
    /**
     * @dev Receive ETH
     */
    receive() external payable {}
}