// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title TRAIDEGovernance
 * @dev Simplified governance contract for TRAIDE ecosystem
 * @notice Implements 1 TRAIDE = 1 vote system with professional DAO functionality
 * 
 * Key Features:
 * - 1 TRAIDE token = 1 vote (direct balance-based voting)
 * - Proposal threshold: 10,000 TRAIDE (prevents spam)
 * - Voting delay: 1 day (24 hours for proposal review)
 * - Voting period: 7 days (1 week voting window)
 * - Quorum: 4% of total token supply
 * - Timelock: 2 days for proposal execution
 */
contract TRAIDEGovernance is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    // TRAIDE token contract
    IERC20 public immutable traideToken;
    
    // TimelockController for proposal execution
    TimelockController public immutable timelock;
    
    // Governance parameters
    uint256 public constant PROPOSAL_THRESHOLD = 10_000 * 10**18; // 10K TRAIDE to create proposals
    uint256 public constant VOTING_DELAY = 1 days; // 24 hours
    uint256 public constant VOTING_PERIOD = 7 days; // 1 week
    uint256 public constant QUORUM_PERCENTAGE = 4; // 4% of total supply
    uint256 public constant TIMELOCK_DELAY = 2 days; // 2 days execution delay

    // Proposal states
    enum ProposalState {
        Pending,    // Proposal created, voting hasn't started
        Active,     // Voting is active
        Canceled,   // Proposal was canceled
        Defeated,   // Proposal was defeated
        Succeeded,  // Proposal passed, ready for queue
        Queued,     // Proposal queued in timelock
        Expired,    // Proposal expired
        Executed    // Proposal executed
    }

    // Proposal structure
    struct Proposal {
        uint256 id;
        address proposer;
        uint256 startTime;
        uint256 endTime;
        string description;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        mapping(address => bool) hasVoted;
        mapping(address => uint8) votes; // 0 = against, 1 = for, 2 = abstain
    }

    // Storage
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    EnumerableSet.UintSet private activeProposals;

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        uint256 startTime,
        uint256 endTime,
        string description
    );

    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 weight,
        string reason
    );

    event ProposalCanceled(uint256 indexed proposalId);
    event ProposalQueued(uint256 indexed proposalId, uint256 executionTime);
    event ProposalExecuted(uint256 indexed proposalId);

    /**
     * @dev Constructor
     * @param _traideToken TRAIDE token contract address
     * @param _timelock TimelockController address
     */
    constructor(
        IERC20 _traideToken,
        TimelockController _timelock
    ) Ownable(msg.sender) {
        traideToken = _traideToken;
        timelock = _timelock;
    }

    /**
     * @dev Create a new proposal
     * @param targets Target addresses for proposal calls
     * @param values Ether values for proposal calls
     * @param calldatas Calldata for proposal calls
     * @param description Human readable description of the proposal
     * @return proposalId The ID of the created proposal
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId) {
        require(
            traideToken.balanceOf(msg.sender) >= PROPOSAL_THRESHOLD,
            "TRAIDEGovernance: proposer votes below proposal threshold"
        );
        
        require(targets.length == values.length, "TRAIDEGovernance: invalid proposal length");
        require(targets.length == calldatas.length, "TRAIDEGovernance: invalid proposal length");
        require(targets.length > 0, "TRAIDEGovernance: empty proposal");

        proposalId = ++proposalCount;
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.startTime = block.timestamp + VOTING_DELAY;
        newProposal.endTime = newProposal.startTime + VOTING_PERIOD;
        newProposal.description = description;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.calldatas = calldatas;
        
        activeProposals.add(proposalId);

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            new string[](targets.length), // empty signatures array
            calldatas,
            newProposal.startTime,
            newProposal.endTime,
            description
        );

        return proposalId;
    }

    /**
     * @dev Cast a vote on a proposal
     * @param proposalId The ID of the proposal to vote on
     * @param support Vote type: 0 = against, 1 = for, 2 = abstain
     * @param reason Voting reason (optional)
     */
    function castVote(
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) external returns (uint256 weight) {
        return _castVote(proposalId, msg.sender, support, reason);
    }

    /**
     * @dev Internal vote casting logic
     */
    function _castVote(
        uint256 proposalId,
        address voter,
        uint8 support,
        string memory reason
    ) internal returns (uint256 weight) {
        ProposalState currentState = state(proposalId);
        require(currentState == ProposalState.Active, "TRAIDEGovernance: vote not currently active");

        Proposal storage proposal = proposals[proposalId];
        require(!proposal.hasVoted[voter], "TRAIDEGovernance: vote already cast");

        weight = traideToken.balanceOf(voter);
        require(weight > 0, "TRAIDEGovernance: voter has no voting power");

        proposal.hasVoted[voter] = true;
        proposal.votes[voter] = support;

        if (support == 0) {
            proposal.againstVotes += weight;
        } else if (support == 1) {
            proposal.forVotes += weight;
        } else if (support == 2) {
            proposal.abstainVotes += weight;
        } else {
            revert("TRAIDEGovernance: invalid vote type");
        }

        emit VoteCast(voter, proposalId, support, weight, reason);

        return weight;
    }

    /**
     * @dev Queue a successful proposal for execution
     * @param proposalId The ID of the proposal to queue
     */
    function queue(uint256 proposalId) external {
        require(state(proposalId) == ProposalState.Succeeded, "TRAIDEGovernance: proposal not successful");

        Proposal storage proposal = proposals[proposalId];
        uint256 executionTime = block.timestamp + TIMELOCK_DELAY;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.schedule(
                proposal.targets[i],
                proposal.values[i],
                proposal.calldatas[i],
                0, // no predecessor
                keccak256(abi.encodePacked(proposalId, i)), // unique salt
                TIMELOCK_DELAY
            );
        }

        emit ProposalQueued(proposalId, executionTime);
    }

    /**
     * @dev Execute a queued proposal
     * @param proposalId The ID of the proposal to execute
     */
    function execute(uint256 proposalId) external nonReentrant {
        require(state(proposalId) == ProposalState.Queued, "TRAIDEGovernance: proposal not queued");

        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            timelock.execute(
                proposal.targets[i],
                proposal.values[i],
                proposal.calldatas[i],
                0, // no predecessor
                keccak256(abi.encodePacked(proposalId, i)) // unique salt
            );
        }

        activeProposals.remove(proposalId);
        emit ProposalExecuted(proposalId);
    }

    /**
     * @dev Cancel a proposal
     * @param proposalId The ID of the proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == owner(),
            "TRAIDEGovernance: only proposer or owner can cancel"
        );
        
        require(state(proposalId) != ProposalState.Executed, "TRAIDEGovernance: cannot cancel executed proposal");
        
        proposal.canceled = true;
        activeProposals.remove(proposalId);
        
        emit ProposalCanceled(proposalId);
    }

    /**
     * @dev Get the current state of a proposal
     * @param proposalId The ID of the proposal
     * @return The current state of the proposal
     */
    function state(uint256 proposalId) public view returns (ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "TRAIDEGovernance: invalid proposal id");
        
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.canceled) {
            return ProposalState.Canceled;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.timestamp < proposal.startTime) {
            return ProposalState.Pending;
        }
        
        if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        }
        
        // Voting has ended, determine result
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        uint256 requiredQuorum = (traideToken.totalSupply() * QUORUM_PERCENTAGE) / 100;
        
        if (totalVotes < requiredQuorum || proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        }
        
        // Check if queued in timelock
        try timelock.isOperationPending(keccak256(abi.encodePacked(proposalId, uint256(0)))) returns (bool pending) {
            if (pending) {
                return ProposalState.Queued;
            }
        } catch {
            // If timelock check fails, assume not queued
        }
        
        // Check if expired (past execution window)
        if (block.timestamp > proposal.endTime + TIMELOCK_DELAY + 7 days) {
            return ProposalState.Expired;
        }
        
        return ProposalState.Succeeded;
    }

    /**
     * @dev Get proposal details
     * @param proposalId The ID of the proposal
     */
    function getProposal(uint256 proposalId) external view returns (
        address proposer,
        uint256 startTime,
        uint256 endTime,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        bool canceled,
        bool executed,
        string memory description
    ) {
        require(proposalId > 0 && proposalId <= proposalCount, "TRAIDEGovernance: invalid proposal id");
        
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.startTime,
            proposal.endTime,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.canceled,
            proposal.executed,
            proposal.description
        );
    }

    /**
     * @dev Get voting power of an account
     * @param account The account to check
     * @return The voting power (TRAIDE balance)
     */
    function getVotes(address account) external view returns (uint256) {
        return traideToken.balanceOf(account);
    }

    /**
     * @dev Check if an account can create proposals
     * @param account The account to check
     * @return True if account can create proposals
     */
    function canCreateProposal(address account) external view returns (bool) {
        return traideToken.balanceOf(account) >= PROPOSAL_THRESHOLD;
    }

    /**
     * @dev Get current quorum requirement
     * @return The current quorum requirement
     */
    function quorum() external view returns (uint256) {
        return (traideToken.totalSupply() * QUORUM_PERCENTAGE) / 100;
    }

    /**
     * @dev Get all active proposal IDs
     * @return Array of active proposal IDs
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        return activeProposals.values();
    }

    /**
     * @dev Check if user has voted on a proposal
     * @param proposalId The proposal ID
     * @param voter The voter address
     * @return True if user has voted
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    /**
     * @dev Get contract version for upgrades
     * @return version Contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @dev Get governance contract info
     * @return name DAO name
     * @return tokenAddress Voting token address
     * @return totalProposals Total number of proposals created
     */
    function getGovernanceInfo() external view returns (
        string memory name,
        address tokenAddress,
        uint256 totalProposals
    ) {
        return ("TRAIDE DAO", address(traideToken), proposalCount);
    }
}