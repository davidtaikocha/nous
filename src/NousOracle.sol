// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgentCouncilOracle} from "./IAgentCouncilOracle.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NousOracle
/// @notice ERC-8033 Agent Council Oracle implementation.
///         A decentralized oracle using multi-agent councils with commit-reveal
///         to resolve arbitrary information queries on-chain.
contract NousOracle is IAgentCouncilOracle, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum Phase {
        None,           // 0
        Committing,     // 1
        Revealing,      // 2
        Judging,        // 3
        Finalized,      // 4  (legacy — kept for UUPS compat, no longer entered post-upgrade)
        Distributed,    // 5
        Failed,         // 6
        DisputeWindow,  // 7
        Disputed,       // 8
        DAOEscalation   // 9
    }

    // ============ Storage ============

    /// @notice Next request ID counter.
    uint256 public nextRequestId;

    /// @notice Duration of the reveal phase after the commit deadline.
    uint256 public revealDuration;

    /// @notice Stored requests by ID.
    mapping(uint256 => Request) internal _requests;

    /// @notice Current phase of each request.
    mapping(uint256 => Phase) public phases;

    /// @notice Committed agents per request (ordered).
    mapping(uint256 => address[]) internal _committedAgents;

    /// @notice Commitment hash per agent per request.
    mapping(uint256 => mapping(address => bytes32)) public commitments;

    /// @notice Revealed agents per request (ordered).
    mapping(uint256 => address[]) internal _revealedAgents;

    /// @notice Revealed answer per agent per request.
    mapping(uint256 => mapping(address => bytes)) internal _revealedAnswers;

    /// @notice Whether an agent has revealed for a request.
    mapping(uint256 => mapping(address => bool)) public hasRevealed;

    /// @notice Selected judge for a request.
    mapping(uint256 => address) public selectedJudge;

    /// @notice Final answer for a request.
    mapping(uint256 => bytes) internal _finalAnswers;

    /// @notice Judge reasoning for a request.
    mapping(uint256 => bytes) internal _reasoning;

    /// @notice Winners for a request.
    mapping(uint256 => address[]) internal _winners;

    /// @notice Approved judges set.
    mapping(address => bool) public isApprovedJudge;
    address[] internal _judgeList;

    /// @notice Reveal phase deadline per request.
    mapping(uint256 => uint256) public revealDeadlines;

    // ============ Dispute Storage ============

    /// @notice Duration of the dispute window in seconds.
    uint256 public disputeWindow;

    /// @notice Multiplier for dispute bond (e.g., 150 = 1.5x original bond). Minimum 100.
    uint256 public disputeBondMultiplier;

    /// @notice Flat bond amount for DAO escalation (in daoEscalationBondToken).
    uint256 public daoEscalationBond;

    /// @notice ERC-20 token used for DAO escalation bonds (Taiko token).
    address public daoEscalationBondToken;

    /// @notice Address authorized to resolve DAO escalations.
    address public daoAddress;

    /// @notice Maximum time for DAO to act on an escalation.
    uint256 public daoResolutionWindow;

    /// @notice Timestamp when the dispute window ends per request.
    mapping(uint256 => uint256) public disputeWindowEnd;

    /// @notice Whether the single dispute has been used for a request.
    mapping(uint256 => bool) public disputeUsed;

    /// @notice Address that filed the dispute for a request.
    mapping(uint256 => address) public disputer;

    /// @notice Actual bond paid by the disputer.
    mapping(uint256 => uint256) public disputeBondPaid;

    /// @notice On-chain reason or IPFS hash for the dispute.
    mapping(uint256 => string) public disputeReason;

    /// @notice Selected judge for the dispute.
    mapping(uint256 => address) public disputeJudge;

    /// @notice Whether DAO escalation has been used for a request.
    mapping(uint256 => bool) public daoEscalationUsed;

    /// @notice Address that filed the DAO escalation.
    mapping(uint256 => address) public daoEscalator;

    /// @notice Actual bond paid for DAO escalation.
    mapping(uint256 => uint256) public daoEscalationBondPaid;

    /// @notice Deadline for DAO to act on an escalation.
    mapping(uint256 => uint256) public daoEscalationDeadline;

    // ============ Errors ============

    error InvalidPhase(uint256 requestId, Phase expected, Phase actual);
    error DeadlineMustBeFuture();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error NumInfoAgentsMustBePositive();
    error InsufficientPayment(uint256 required, uint256 provided);
    error MaxAgentsReached(uint256 requestId);
    error AlreadyCommitted(uint256 requestId, address agent);
    error CommitmentNotFound(uint256 requestId, address agent);
    error AlreadyRevealed(uint256 requestId, address agent);
    error CommitmentMismatch(uint256 requestId, address agent);
    error QuorumNotMet(uint256 requestId, uint256 revealed, uint256 required);
    error NotSelectedJudge(uint256 requestId, address caller);
    error WinnerNotRevealed(uint256 requestId, address winner);
    error NoJudgesAvailable();
    error NoWinners();
    error TransferFailed();

    // ============ Dispute Events ============

    event DisputeInitiated(uint256 indexed requestId, address disputer, string reason);
    event DisputeWindowOpened(uint256 indexed requestId, uint256 endTimestamp);
    event DisputeResolved(uint256 indexed requestId, bool overturned, bytes finalAnswer);
    event DAOEscalationInitiated(uint256 indexed requestId, address escalator);
    event DAOEscalationResolved(uint256 indexed requestId, bytes finalAnswer);
    event DAOEscalationTimedOut(uint256 indexed requestId);

    event DisputeWindowUpdated(uint256 oldDuration, uint256 newDuration);
    event DisputeBondMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
    event DaoEscalationBondUpdated(uint256 oldAmount, uint256 newAmount);
    event DaoEscalationBondTokenUpdated(address oldToken, address newToken);
    event DaoAddressUpdated(address oldDao, address newDao);
    event DaoResolutionWindowUpdated(uint256 oldDuration, uint256 newDuration);

    // ============ Dispute Errors ============

    error DisputeWindowNotOpen(uint256 requestId);
    error DisputeWindowNotExpired(uint256 requestId);
    error DisputeAlreadyUsed(uint256 requestId);
    error DisputeRequired(uint256 requestId);
    error InsufficientDisputeBond(uint256 required, uint256 provided);
    error NotDisputeJudge(uint256 requestId, address caller);
    error NoDisputeJudgeAvailable(uint256 requestId);
    error DAOEscalationAlreadyUsed(uint256 requestId);
    error DAONotSet();
    error NotDAO(address caller);
    error DAODeadlineNotPassed(uint256 requestId);
    error DAOResolutionTimedOut(uint256 requestId);
    error DisputeBondMultiplierTooLow(uint256 multiplier);
    error InvalidBondTokenAddress();
    error ETHSentWithERC20Bond();

    // ============ Initializer ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle.
    /// @param owner_ The owner address (manages judges, upgrades).
    /// @param revealDuration_ Duration in seconds for the reveal phase.
    function initialize(address owner_, uint256 revealDuration_) external initializer {
        __Ownable_init(owner_);
        revealDuration = revealDuration_;
        nextRequestId = 1;
    }

    // ============ Judge Management ============

    /// @notice Add an approved judge.
    function addJudge(address judge) external onlyOwner {
        if (!isApprovedJudge[judge]) {
            isApprovedJudge[judge] = true;
            _judgeList.push(judge);
        }
    }

    /// @notice Remove an approved judge.
    function removeJudge(address judge) external onlyOwner {
        if (isApprovedJudge[judge]) {
            isApprovedJudge[judge] = false;
            uint256 len = _judgeList.length;
            for (uint256 i; i < len; ++i) {
                if (_judgeList[i] == judge) {
                    _judgeList[i] = _judgeList[len - 1];
                    _judgeList.pop();
                    break;
                }
            }
        }
    }

    /// @notice Get all approved judges.
    function getJudges() external view returns (address[] memory) {
        return _judgeList;
    }

    // ============ Dispute Configuration ============

    /// @notice Set the dispute window duration.
    function setDisputeWindow(uint256 duration) external onlyOwner {
        uint256 old = disputeWindow;
        disputeWindow = duration;
        emit DisputeWindowUpdated(old, duration);
    }

    /// @notice Set the dispute bond multiplier (minimum 100 = 1x).
    function setDisputeBondMultiplier(uint256 multiplier) external onlyOwner {
        if (multiplier < 100) revert DisputeBondMultiplierTooLow(multiplier);
        uint256 old = disputeBondMultiplier;
        disputeBondMultiplier = multiplier;
        emit DisputeBondMultiplierUpdated(old, multiplier);
    }

    /// @notice Set the flat DAO escalation bond amount.
    function setDaoEscalationBond(uint256 amount) external onlyOwner {
        uint256 old = daoEscalationBond;
        daoEscalationBond = amount;
        emit DaoEscalationBondUpdated(old, amount);
    }

    /// @notice Set the ERC-20 token for DAO escalation bonds.
    function setDaoEscalationBondToken(address token_) external onlyOwner {
        if (token_ == address(0)) revert InvalidBondTokenAddress();
        address old = daoEscalationBondToken;
        daoEscalationBondToken = token_;
        emit DaoEscalationBondTokenUpdated(old, token_);
    }

    /// @notice Set the DAO address for escalation resolution.
    function setDaoAddress(address dao) external onlyOwner {
        address old = daoAddress;
        daoAddress = dao;
        emit DaoAddressUpdated(old, dao);
    }

    /// @notice Set the maximum time for DAO to resolve an escalation.
    function setDaoResolutionWindow(uint256 duration) external onlyOwner {
        uint256 old = daoResolutionWindow;
        daoResolutionWindow = duration;
        emit DaoResolutionWindowUpdated(old, duration);
    }

    // ============ Core Functions ============

    /// @inheritdoc IAgentCouncilOracle
    function createRequest(
        string calldata query,
        uint256 numInfoAgents,
        uint256 rewardAmount,
        uint256 bondAmount,
        uint256 deadline,
        address rewardToken,
        address bondToken,
        string calldata specifications,
        AgentCapabilities calldata requiredCapabilities
    ) external payable returns (uint256 requestId) {
        if (deadline <= block.timestamp) revert DeadlineMustBeFuture();
        if (numInfoAgents == 0) revert NumInfoAgentsMustBePositive();
        if (_judgeList.length == 0) revert NoJudgesAvailable();

        // Collect reward from requester
        if (rewardToken == address(0)) {
            if (msg.value < rewardAmount) {
                revert InsufficientPayment(rewardAmount, msg.value);
            }
            // Refund excess
            uint256 excess = msg.value - rewardAmount;
            if (excess > 0) {
                (bool ok,) = msg.sender.call{value: excess}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), rewardAmount);
        }

        requestId = nextRequestId++;

        Request storage req = _requests[requestId];
        req.requester = msg.sender;
        req.rewardAmount = rewardAmount;
        req.rewardToken = rewardToken;
        req.bondAmount = bondAmount;
        req.bondToken = bondToken;
        req.numInfoAgents = numInfoAgents;
        req.deadline = deadline;
        req.query = query;
        req.specifications = specifications;
        req.requiredCapabilities = requiredCapabilities;

        phases[requestId] = Phase.Committing;

        emit RequestCreated(requestId, msg.sender, query, rewardAmount, numInfoAgents, bondAmount);
    }

    /// @inheritdoc IAgentCouncilOracle
    function commit(uint256 requestId, bytes32 commitment) external payable {
        _requirePhase(requestId, Phase.Committing);

        Request storage req = _requests[requestId];
        if (block.timestamp > req.deadline) revert DeadlinePassed();
        if (_committedAgents[requestId].length >= req.numInfoAgents) {
            revert MaxAgentsReached(requestId);
        }
        if (commitments[requestId][msg.sender] != bytes32(0)) {
            revert AlreadyCommitted(requestId, msg.sender);
        }

        // Collect bond
        if (req.bondToken == address(0)) {
            if (msg.value < req.bondAmount) {
                revert InsufficientPayment(req.bondAmount, msg.value);
            }
            uint256 excess = msg.value - req.bondAmount;
            if (excess > 0) {
                (bool ok,) = msg.sender.call{value: excess}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            IERC20(req.bondToken).safeTransferFrom(msg.sender, address(this), req.bondAmount);
        }

        commitments[requestId][msg.sender] = commitment;
        _committedAgents[requestId].push(msg.sender);

        emit AgentCommitted(requestId, msg.sender, commitment);

        // Auto-transition to revealing when max agents reached
        if (_committedAgents[requestId].length == req.numInfoAgents) {
            phases[requestId] = Phase.Revealing;
            revealDeadlines[requestId] = block.timestamp + revealDuration;
        }
    }

    /// @notice Manually transition from Committing to Revealing after deadline.
    ///         Anyone can call this once the commit deadline has passed.
    function endCommitPhase(uint256 requestId) external {
        _requirePhase(requestId, Phase.Committing);

        Request storage req = _requests[requestId];
        if (block.timestamp <= req.deadline) revert DeadlineNotPassed();

        if (_committedAgents[requestId].length == 0) {
            // No agents committed — fail and refund requester
            phases[requestId] = Phase.Failed;
            _refundRequester(requestId);
            emit ResolutionFailed(requestId, "No agents committed");
            return;
        }

        phases[requestId] = Phase.Revealing;
        revealDeadlines[requestId] = block.timestamp + revealDuration;
    }

    /// @inheritdoc IAgentCouncilOracle
    function reveal(uint256 requestId, bytes calldata answer, uint256 nonce) external {
        _requirePhase(requestId, Phase.Revealing);

        if (block.timestamp > revealDeadlines[requestId]) revert DeadlinePassed();
        if (commitments[requestId][msg.sender] == bytes32(0)) {
            revert CommitmentNotFound(requestId, msg.sender);
        }
        if (hasRevealed[requestId][msg.sender]) {
            revert AlreadyRevealed(requestId, msg.sender);
        }

        // Verify commitment
        bytes32 expected = keccak256(abi.encode(answer, nonce));
        if (expected != commitments[requestId][msg.sender]) {
            revert CommitmentMismatch(requestId, msg.sender);
        }

        hasRevealed[requestId][msg.sender] = true;
        _revealedAgents[requestId].push(msg.sender);
        _revealedAnswers[requestId][msg.sender] = answer;

        emit AgentRevealed(requestId, msg.sender, answer);

        // Auto-transition if all committed agents have revealed
        if (_revealedAgents[requestId].length == _committedAgents[requestId].length) {
            _transitionToJudging(requestId);
        }
    }

    /// @notice Manually transition from Revealing to Judging after reveal deadline.
    ///         Checks quorum (>50% of committed agents must have revealed).
    function endRevealPhase(uint256 requestId) external {
        _requirePhase(requestId, Phase.Revealing);

        if (block.timestamp <= revealDeadlines[requestId]) revert DeadlineNotPassed();

        uint256 committed = _committedAgents[requestId].length;
        uint256 revealed = _revealedAgents[requestId].length;
        uint256 quorum = (committed / 2) + 1; // 50% + 1

        if (revealed < quorum) {
            // Quorum not met — fail, refund requester, return bonds to revealers
            phases[requestId] = Phase.Failed;
            _refundRequester(requestId);
            _refundRevealedAgentBonds(requestId);
            emit ResolutionFailed(requestId, "Quorum not met");
            return;
        }

        _transitionToJudging(requestId);
    }

    /// @inheritdoc IAgentCouncilOracle
    function aggregate(
        uint256 requestId,
        bytes calldata finalAnswer,
        address[] calldata winners,
        bytes calldata reasoning
    ) external {
        _requirePhase(requestId, Phase.Judging);

        if (msg.sender != selectedJudge[requestId]) {
            revert NotSelectedJudge(requestId, msg.sender);
        }
        if (winners.length == 0) revert NoWinners();

        // Validate all winners actually revealed
        for (uint256 i; i < winners.length; ++i) {
            if (!hasRevealed[requestId][winners[i]]) {
                revert WinnerNotRevealed(requestId, winners[i]);
            }
        }

        _finalAnswers[requestId] = finalAnswer;
        _reasoning[requestId] = reasoning;
        _winners[requestId] = winners;
        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp + disputeWindow;

        emit ResolutionFinalized(requestId, finalAnswer);
        emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
    }

    /// @inheritdoc IAgentCouncilOracle
    function distributeRewards(uint256 requestId) external {
        Phase phase = phases[requestId];

        if (phase == Phase.DisputeWindow) {
            if (block.timestamp < disputeWindowEnd[requestId]) {
                revert DisputeWindowNotExpired(requestId);
            }
        } else if (phase == Phase.Finalized) {
            // Legacy path: pre-upgrade requests can distribute immediately
        } else {
            revert InvalidPhase(requestId, Phase.DisputeWindow, phase);
        }

        Request storage req = _requests[requestId];
        address[] storage winners = _winners[requestId];
        uint256 numWinners = winners.length;

        uint256 rewardPerWinner = req.rewardAmount / numWinners;
        uint256 totalSlashed = _calculateSlashedBonds(requestId);
        uint256 slashPerWinner = numWinners > 0 ? totalSlashed / numWinners : 0;

        address[] memory winnerList = new address[](numWinners);
        uint256[] memory amounts = new uint256[](numWinners);

        for (uint256 i; i < numWinners; ++i) {
            address winner = winners[i];
            winnerList[i] = winner;

            uint256 totalPayout = rewardPerWinner;
            if (req.rewardToken == address(0)) {
                (bool ok,) = winner.call{value: rewardPerWinner}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(req.rewardToken).safeTransfer(winner, rewardPerWinner);
            }

            uint256 bondPayout = req.bondAmount + slashPerWinner;
            totalPayout += bondPayout;
            if (req.bondToken == address(0)) {
                (bool ok,) = winner.call{value: bondPayout}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(req.bondToken).safeTransfer(winner, bondPayout);
            }

            amounts[i] = totalPayout;
        }

        phases[requestId] = Phase.Distributed;
        emit RewardsDistributed(requestId, winnerList, amounts);
    }

    // ============ Dispute Functions ============

    /// @notice File a dispute against the judge's decision.
    /// @param requestId The request to dispute.
    /// @param reason On-chain reason or IPFS hash of detailed reasoning.
    function initiateDispute(uint256 requestId, string calldata reason) external payable {
        _requirePhase(requestId, Phase.DisputeWindow);
        if (block.timestamp >= disputeWindowEnd[requestId]) revert DisputeWindowNotOpen(requestId);
        if (disputeUsed[requestId]) revert DisputeAlreadyUsed(requestId);

        Request storage req = _requests[requestId];
        uint256 requiredBond = req.bondAmount * disputeBondMultiplier / 100;

        if (req.bondToken == address(0)) {
            if (msg.value < requiredBond) revert InsufficientDisputeBond(requiredBond, msg.value);
            uint256 excess = msg.value - requiredBond;
            if (excess > 0) {
                (bool ok,) = msg.sender.call{value: excess}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            if (msg.value > 0) revert ETHSentWithERC20Bond();
            IERC20(req.bondToken).safeTransferFrom(msg.sender, address(this), requiredBond);
        }

        disputer[requestId] = msg.sender;
        disputeBondPaid[requestId] = requiredBond;
        disputeReason[requestId] = reason;
        disputeUsed[requestId] = true;

        _selectDisputeJudge(requestId);

        phases[requestId] = Phase.Disputed;

        emit DisputeInitiated(requestId, msg.sender, reason);
    }

    /// @notice Resolve a dispute. Called by the selected dispute judge.
    /// @param requestId The disputed request.
    /// @param overturn True to overturn the original decision.
    /// @param newAnswer New final answer (only used if overturn=true).
    /// @param newWinners New winners (only used if overturn=true).
    function resolveDispute(
        uint256 requestId,
        bool overturn,
        bytes calldata newAnswer,
        address[] calldata newWinners
    ) external {
        _requirePhase(requestId, Phase.Disputed);
        if (msg.sender != disputeJudge[requestId]) revert NotDisputeJudge(requestId, msg.sender);

        Request storage req = _requests[requestId];
        uint256 bondAmount = disputeBondPaid[requestId];

        if (overturn) {
            if (newWinners.length == 0) revert NoWinners();
            for (uint256 i; i < newWinners.length; ++i) {
                if (!hasRevealed[requestId][newWinners[i]]) {
                    revert WinnerNotRevealed(requestId, newWinners[i]);
                }
            }

            _transferToken(req.bondToken, disputer[requestId], bondAmount);

            _finalAnswers[requestId] = newAnswer;
            _winners[requestId] = newWinners;
        } else {
            _distributeForfeitedBond(requestId, req.bondToken, bondAmount, req.requester);
        }

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp + disputeWindow;

        emit DisputeResolved(requestId, overturn, _finalAnswers[requestId]);
        emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
    }

    /// @notice Escalate to DAO after dispute resolution.
    /// @param requestId The request to escalate.
    function initiateDAOEscalation(uint256 requestId) external {
        _requirePhase(requestId, Phase.DisputeWindow);
        if (block.timestamp >= disputeWindowEnd[requestId]) revert DisputeWindowNotOpen(requestId);
        if (!disputeUsed[requestId]) revert DisputeRequired(requestId);
        if (daoEscalationUsed[requestId]) revert DAOEscalationAlreadyUsed(requestId);
        if (daoAddress == address(0)) revert DAONotSet();

        IERC20(daoEscalationBondToken).safeTransferFrom(msg.sender, address(this), daoEscalationBond);

        daoEscalator[requestId] = msg.sender;
        daoEscalationBondPaid[requestId] = daoEscalationBond;
        daoEscalationUsed[requestId] = true;
        daoEscalationDeadline[requestId] = block.timestamp + daoResolutionWindow;

        phases[requestId] = Phase.DAOEscalation;

        emit DAOEscalationInitiated(requestId, msg.sender);
    }

    /// @notice Resolve a DAO escalation. Called by the DAO address.
    /// @param requestId The escalated request.
    /// @param overturn True to overturn the current decision.
    /// @param newAnswer New final answer (only used if overturn=true).
    /// @param newWinners New winners (only used if overturn=true).
    function resolveDAOEscalation(
        uint256 requestId,
        bool overturn,
        bytes calldata newAnswer,
        address[] calldata newWinners
    ) external {
        _requirePhase(requestId, Phase.DAOEscalation);
        if (msg.sender != daoAddress) revert NotDAO(msg.sender);
        if (block.timestamp > daoEscalationDeadline[requestId]) revert DAOResolutionTimedOut(requestId);

        uint256 bondAmount = daoEscalationBondPaid[requestId];

        if (overturn) {
            if (newWinners.length == 0) revert NoWinners();
            for (uint256 i; i < newWinners.length; ++i) {
                if (!hasRevealed[requestId][newWinners[i]]) {
                    revert WinnerNotRevealed(requestId, newWinners[i]);
                }
            }

            IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], bondAmount);

            _finalAnswers[requestId] = newAnswer;
            _winners[requestId] = newWinners;
        } else {
            Request storage req = _requests[requestId];
            _distributeForfeitedBond(requestId, daoEscalationBondToken, bondAmount, req.requester);
        }

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp;

        emit DAOEscalationResolved(requestId, _finalAnswers[requestId]);
    }

    /// @notice Timeout a DAO escalation if the DAO fails to act.
    ///         Anyone can call after the deadline passes.
    /// @param requestId The escalated request.
    function timeoutDAOEscalation(uint256 requestId) external {
        _requirePhase(requestId, Phase.DAOEscalation);
        if (block.timestamp <= daoEscalationDeadline[requestId]) revert DAODeadlineNotPassed(requestId);

        IERC20(daoEscalationBondToken).safeTransfer(
            daoEscalator[requestId],
            daoEscalationBondPaid[requestId]
        );

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp;

        emit DAOEscalationTimedOut(requestId);
    }

    // ============ View Functions ============

    /// @inheritdoc IAgentCouncilOracle
    function getResolution(uint256 requestId) external view returns (bytes memory finalAnswer, bool finalized) {
        Phase phase = phases[requestId];
        finalized = phase == Phase.Distributed;
        finalAnswer = _finalAnswers[requestId];
    }

    /// @inheritdoc IAgentCouncilOracle
    function getRequest(uint256 requestId) external view returns (Request memory) {
        return _requests[requestId];
    }

    /// @inheritdoc IAgentCouncilOracle
    function getCommits(uint256 requestId)
        external
        view
        returns (address[] memory agents, bytes32[] memory commitHash)
    {
        agents = _committedAgents[requestId];
        commitHash = new bytes32[](agents.length);
        for (uint256 i; i < agents.length; ++i) {
            commitHash[i] = commitments[requestId][agents[i]];
        }
    }

    /// @inheritdoc IAgentCouncilOracle
    function getReveals(uint256 requestId) external view returns (address[] memory agents, bytes[] memory answers) {
        agents = _revealedAgents[requestId];
        answers = new bytes[](agents.length);
        for (uint256 i; i < agents.length; ++i) {
            answers[i] = _revealedAnswers[requestId][agents[i]];
        }
    }

    /// @notice Get the judge's reasoning for a finalized request.
    function getReasoning(uint256 requestId) external view returns (bytes memory) {
        return _reasoning[requestId];
    }

    /// @notice Get the winners for a finalized request.
    function getWinners(uint256 requestId) external view returns (address[] memory) {
        return _winners[requestId];
    }

    // ============ Internal ============

    function _requirePhase(uint256 requestId, Phase expected) internal view {
        Phase actual = phases[requestId];
        if (actual != expected) revert InvalidPhase(requestId, expected, actual);
    }

    function _transitionToJudging(uint256 requestId) internal {
        // Pseudo-random judge selection from the approved pool
        uint256 judgeCount = _judgeList.length;
        if (judgeCount == 0) revert NoJudgesAvailable();

        uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId)));
        address judge = _judgeList[seed % judgeCount];

        selectedJudge[requestId] = judge;
        phases[requestId] = Phase.Judging;

        emit JudgeSelected(requestId, judge);
    }

    function _refundRequester(uint256 requestId) internal {
        Request storage req = _requests[requestId];
        if (req.rewardAmount == 0) return;

        if (req.rewardToken == address(0)) {
            (bool ok,) = req.requester.call{value: req.rewardAmount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(req.rewardToken).safeTransfer(req.requester, req.rewardAmount);
        }
    }

    function _refundRevealedAgentBonds(uint256 requestId) internal {
        Request storage req = _requests[requestId];
        if (req.bondAmount == 0) return;

        address[] storage agents = _revealedAgents[requestId];
        for (uint256 i; i < agents.length; ++i) {
            if (req.bondToken == address(0)) {
                (bool ok,) = agents[i].call{value: req.bondAmount}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(req.bondToken).safeTransfer(agents[i], req.bondAmount);
            }
        }
    }

    function _calculateSlashedBonds(uint256 requestId) internal view returns (uint256) {
        Request storage req = _requests[requestId];
        address[] storage winners = _winners[requestId];
        address[] storage revealed = _revealedAgents[requestId];

        // Build a quick lookup of winners
        uint256 numWinners = winners.length;
        uint256 losers = 0;

        for (uint256 i; i < revealed.length; ++i) {
            bool isWinner = false;
            for (uint256 j; j < numWinners; ++j) {
                if (revealed[i] == winners[j]) {
                    isWinner = true;
                    break;
                }
            }
            if (!isWinner) losers++;
        }

        // Also count non-revealers as losers (their bonds are also slashed)
        uint256 committed = _committedAgents[requestId].length;
        uint256 nonRevealers = committed - revealed.length;
        losers += nonRevealers;

        return losers * req.bondAmount;
    }

    /// @dev Transfer a token (ETH or ERC-20) to a recipient.
    function _transferToken(address token_, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token_ == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token_).safeTransfer(to, amount);
        }
    }

    /// @dev Distribute a forfeited bond: 50% to current winners (split equally), 50% to requester.
    function _distributeForfeitedBond(
        uint256 requestId,
        address token_,
        uint256 bondAmount,
        address requesterAddr
    ) internal {
        uint256 requesterShare = bondAmount / 2;
        uint256 winnersTotal = bondAmount - requesterShare;
        address[] storage winners = _winners[requestId];
        uint256 numWinners = winners.length;

        _transferToken(token_, requesterAddr, requesterShare);

        if (numWinners > 0) {
            uint256 perWinner = winnersTotal / numWinners;
            for (uint256 i; i < numWinners; ++i) {
                _transferToken(token_, winners[i], perWinner);
            }
        }
    }

    function _selectDisputeJudge(uint256 requestId) internal {
        address originalJudge = selectedJudge[requestId];
        uint256 judgeCount = _judgeList.length;

        uint256 eligible = 0;
        for (uint256 i; i < judgeCount; ++i) {
            if (_judgeList[i] != originalJudge) eligible++;
        }
        if (eligible == 0) revert NoDisputeJudgeAvailable(requestId);

        uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId, "dispute")));
        uint256 pick = seed % eligible;

        uint256 count = 0;
        for (uint256 i; i < judgeCount; ++i) {
            if (_judgeList[i] != originalJudge) {
                if (count == pick) {
                    disputeJudge[requestId] = _judgeList[i];
                    return;
                }
                count++;
            }
        }
    }

    /// @notice UUPS authorization — only owner can upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
