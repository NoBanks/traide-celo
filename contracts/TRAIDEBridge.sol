// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title TRAIDEBridge
 * @dev Cross-chain bridge for TRAIDE ecosystem assets
 * August 2025 Standards - Secure multi-signature bridge with validator consensus
 */
contract TRAIDEBridge is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    
    struct BridgeTransaction {
        address token;
        address from;
        address to;
        uint256 amount;
        uint256 targetChainId;
        uint256 nonce;
        uint256 timestamp;
        bool processed;
    }
    
    struct ValidatorInfo {
        address validator;
        bool isActive;
        uint256 addedAt;
    }
    
    mapping(bytes32 => BridgeTransaction) public bridgeTransactions;
    mapping(bytes32 => mapping(address => bool)) public validatorSignatures;
    mapping(bytes32 => uint256) public signatureCount;
    mapping(address => ValidatorInfo) public validators;
    mapping(address => bool) public supportedTokens;
    mapping(uint256 => bool) public supportedChains;
    mapping(address => uint256) public nonces;
    
    address[] public validatorList;
    uint256 public requiredSignatures = 3;
    uint256 public bridgeFee = 1000; // 0.1% in basis points
    uint256 public constant FEE_PRECISION = 1000000;
    uint256 public constant MAX_BRIDGE_AMOUNT = 1000000 * 1e18; // 1M tokens max
    uint256 public constant MIN_BRIDGE_AMOUNT = 1e18; // 1 token min
    
    event BridgeInitiated(
        bytes32 indexed txId,
        address indexed token,
        address indexed from,
        address to,
        uint256 amount,
        uint256 targetChainId,
        uint256 nonce
    );
    
    event BridgeCompleted(
        bytes32 indexed txId,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event TokenSupported(address indexed token);
    event ChainSupported(uint256 indexed chainId);
    event SignatureSubmitted(bytes32 indexed txId, address indexed validator);
    
    error InvalidValidator();
    error InsufficientSignatures();
    error TransactionAlreadyProcessed();
    error UnsupportedToken();
    error UnsupportedChain();
    error InvalidAmount();
    error InvalidSignature();
    error DuplicateSignature();
    
    constructor() Ownable(msg.sender) {}
    
    modifier onlyValidator() {
        if (!validators[msg.sender].isActive) revert InvalidValidator();
        _;
    }
    
    /**
     * @dev Initiate bridge transaction to another chain
     */
    function bridge(
        address token,
        address to,
        uint256 amount,
        uint256 targetChainId
    ) external nonReentrant returns (bytes32 txId) {
        if (!supportedTokens[token]) revert UnsupportedToken();
        if (!supportedChains[targetChainId]) revert UnsupportedChain();
        if (amount < MIN_BRIDGE_AMOUNT || amount > MAX_BRIDGE_AMOUNT) revert InvalidAmount();
        
        uint256 userNonce = nonces[msg.sender]++;
        
        txId = keccak256(abi.encodePacked(
            token,
            msg.sender,
            to,
            amount,
            targetChainId,
            userNonce,
            block.chainid,
            block.timestamp
        ));
        
        // Calculate bridge fee
        uint256 fee = (amount * bridgeFee) / FEE_PRECISION;
        uint256 bridgeAmount = amount - fee;
        
        // Lock tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Store transaction
        bridgeTransactions[txId] = BridgeTransaction({
            token: token,
            from: msg.sender,
            to: to,
            amount: bridgeAmount,
            targetChainId: targetChainId,
            nonce: userNonce,
            timestamp: block.timestamp,
            processed: false
        });
        
        emit BridgeInitiated(txId, token, msg.sender, to, bridgeAmount, targetChainId, userNonce);
        return txId;
    }
    
    /**
     * @dev Submit validator signature for bridge completion
     */
    function submitSignature(
        bytes32 txId,
        bytes memory signature
    ) external onlyValidator {
        if (validatorSignatures[txId][msg.sender]) revert DuplicateSignature();
        
        BridgeTransaction memory bridgeTx = bridgeTransactions[txId];
        if (bridgeTx.processed) revert TransactionAlreadyProcessed();
        
        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            txId,
            bridgeTx.token,
            bridgeTx.to,
            bridgeTx.amount,
            block.chainid
        )).toEthSignedMessageHash();
        
        address signer = messageHash.recover(signature);
        if (signer != msg.sender || !validators[signer].isActive) revert InvalidSignature();
        
        // Record signature
        validatorSignatures[txId][msg.sender] = true;
        signatureCount[txId]++;
        
        emit SignatureSubmitted(txId, msg.sender);
        
        // Complete bridge if enough signatures
        if (signatureCount[txId] >= requiredSignatures) {
            _completeBridge(txId);
        }
    }
    
    /**
     * @dev Complete bridge transaction (internal)
     */
    function _completeBridge(bytes32 txId) internal {
        BridgeTransaction storage bridgeTx = bridgeTransactions[txId];
        if (bridgeTx.processed) revert TransactionAlreadyProcessed();
        
        bridgeTx.processed = true;
        
        // Release tokens to recipient
        IERC20(bridgeTx.token).safeTransfer(bridgeTx.to, bridgeTx.amount);
        
        emit BridgeCompleted(txId, bridgeTx.token, bridgeTx.to, bridgeTx.amount);
    }
    
    /**
     * @dev Add validator
     */
    function addValidator(address validator) external onlyOwner {
        require(!validators[validator].isActive, "Validator already active");
        
        validators[validator] = ValidatorInfo({
            validator: validator,
            isActive: true,
            addedAt: block.timestamp
        });
        
        validatorList.push(validator);
        emit ValidatorAdded(validator);
    }
    
    /**
     * @dev Remove validator
     */
    function removeValidator(address validator) external onlyOwner {
        require(validators[validator].isActive, "Validator not active");
        
        validators[validator].isActive = false;
        
        // Remove from list
        for (uint256 i = 0; i < validatorList.length; i++) {
            if (validatorList[i] == validator) {
                validatorList[i] = validatorList[validatorList.length - 1];
                validatorList.pop();
                break;
            }
        }
        
        emit ValidatorRemoved(validator);
    }
    
    /**
     * @dev Add supported token
     */
    function addSupportedToken(address token) external onlyOwner {
        supportedTokens[token] = true;
        emit TokenSupported(token);
    }
    
    /**
     * @dev Add supported chain
     */
    function addSupportedChain(uint256 chainId) external onlyOwner {
        supportedChains[chainId] = true;
        emit ChainSupported(chainId);
    }
    
    /**
     * @dev Update required signatures threshold
     */
    function setRequiredSignatures(uint256 _required) external onlyOwner {
        require(_required > 0 && _required <= validatorList.length, "Invalid signature count");
        requiredSignatures = _required;
    }
    
    /**
     * @dev Update bridge fee
     */
    function setBridgeFee(uint256 _fee) external onlyOwner {
        require(_fee <= 10000, "Fee too high"); // Max 1%
        bridgeFee = _fee;
    }
    
    /**
     * @dev Emergency withdraw (owner only)
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    /**
     * @dev Get validator count
     */
    function getValidatorCount() external view returns (uint256) {
        return validatorList.length;
    }
    
    /**
     * @dev Check if transaction has enough signatures
     */
    function hasEnoughSignatures(bytes32 txId) external view returns (bool) {
        return signatureCount[txId] >= requiredSignatures;
    }
}