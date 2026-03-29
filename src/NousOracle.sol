// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAgentCouncilOracle} from "./IAgentCouncilOracle.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NousOracle
/// @notice ERC-8033 Agent Council Oracle implementation.
///         A decentralized oracle using multi-agent councils with commit-reveal
///         to resolve arbitrary information queries on-chain.
contract NousOracle is IAgentCouncilOracle, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum Phase {
        None, // 0
        Committing, // 1
        Revealing, // 2
        Judging, // 3
        Finalized, // 4  (legacy — kept for UUPS compat, no longer entered post-upgrade)
        Distributed, // 5
        Failed, // 6
        DisputeWindow, // 7
        Disputed, // 8
        DAOEscalation // 9
    }

    enum AgentRole {
        Info,
        Judge
    }

    struct AgentStake {
        uint256 amount;
        AgentRole role;
        bool registered;
        uint256 withdrawRequestTime;
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

    /// @notice Per-request dispute window override. 0 = use global default.
    mapping(uint256 => uint256) public requestDisputeWindow;

    // ============ Staking Storage ============

    /// @notice Stake info per agent address.
    mapping(address => AgentStake) public agentStakes;

    /// @notice Registered info agents pool.
    address[] internal _registeredInfoAgents;

    /// @notice Registered judges pool.
    address[] internal _registeredJudges;

    /// @notice Minimum stake required to register.
    uint256 public minStakeAmount;

    /// @notice Slash percentage in basis points (e.g., 5000 = 50%).
    uint256 public slashPercentage;

    /// @notice Cooldown duration in seconds before withdrawal completes.
    uint256 public withdrawalCooldown;

    /// @notice Token used for staking (address(0) = native ETH).
    address public stakeToken;

    /// @notice Selected info agents per request.
    mapping(uint256 => address[]) internal _selectedAgents;

    /// @notice Number of active request assignments per agent.
    mapping(address => uint256) public activeAssignments;

    /// @notice Accumulated slashed stake per request.
    mapping(uint256 => uint256) public requestSlashedStake;

    /// @notice Flat dispute bond for post-upgrade requests (no bondAmount).
    uint256 public disputeBondAmount;

    /// @notice Judge to slash at distribution time.
    mapping(uint256 => address) public judgeToSlash;

    /// @notice Beneficiary of 50% of slashed judge stake.
    mapping(uint256 => address) public slashBeneficiary;

    /// @notice Agents slashed during this request (for restore on inconclusive).
    mapping(uint256 => address[]) internal _slashedAgents;

    /// @notice Amount slashed per agent per request.
    mapping(uint256 => mapping(address => uint256)) internal _slashedAmounts;

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

    // ============ Staking Events ============

    event AgentRegistered(address indexed agent, AgentRole role, uint256 amount);
    event StakeAdded(address indexed agent, uint256 amount, uint256 newTotal);
    event WithdrawalRequested(address indexed agent, uint256 timestamp);
    event WithdrawalExecuted(address indexed agent, uint256 amount);
    event WithdrawalCancelled(address indexed agent);
    event AgentSlashed(address indexed agent, uint256 amount, uint256 remaining);
    event AgentDeregistered(address indexed agent);
    event AgentSelected(uint256 indexed requestId, address agent);
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event SlashPercentageUpdated(uint256 oldPct, uint256 newPct);
    event WithdrawalCooldownUpdated(uint256 oldDuration, uint256 newDuration);
    event DisputeBondAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event JudgeSlashed(uint256 indexed requestId, address judge, uint256 amount, address beneficiary);
    event InconclusiveResolution(uint256 indexed requestId);
    event StakeRestored(address indexed agent, uint256 amount);

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

    // ============ Staking Errors ============

    error AlreadyRegistered(address agent);
    error NotRegistered(address agent);
    error InsufficientStake(uint256 required, uint256 provided);
    error NotSelectedForRequest(uint256 requestId, address agent);
    error InsufficientRegisteredAgents(uint256 required, uint256 available);
    error ActiveAssignmentsPending(address agent, uint256 count);
    error WithdrawalNotRequested(address agent);
    error WithdrawalCooldownNotElapsed(address agent, uint256 readyAt);
    error WithdrawalAlreadyRequested(address agent);
    error StakeBelowMinimum(address agent, uint256 current, uint256 minimum);
    error SlashPercentageTooHigh(uint256 pct);
    error NoRegisteredAgents();
    error RewardTokenMustBeStakeToken(address expected, address provided);
    error InvalidDAOOutcome(uint8 outcome);

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

    /// @notice Set a per-request dispute window duration. Only callable by the requester during Committing phase.
    /// @param requestId The request to configure.
    /// @param duration Duration in seconds. 0 = use global default.
    function setRequestDisputeWindow(uint256 requestId, uint256 duration) external {
        _requirePhase(requestId, Phase.Committing);
        if (msg.sender != _requests[requestId].requester) revert NotSelectedJudge(requestId, msg.sender); // reuse error: not requester
        requestDisputeWindow[requestId] = duration;
    }

    // ============ Staking Configuration ============

    /// @notice Set the minimum stake amount.
    function setMinStakeAmount(uint256 amount) external onlyOwner {
        uint256 old = minStakeAmount;
        minStakeAmount = amount;
        emit MinStakeAmountUpdated(old, amount);
    }

    /// @notice Set the slash percentage in basis points (max 10000).
    function setSlashPercentage(uint256 basisPoints) external onlyOwner {
        if (basisPoints > 10000) revert SlashPercentageTooHigh(basisPoints);
        uint256 old = slashPercentage;
        slashPercentage = basisPoints;
        emit SlashPercentageUpdated(old, basisPoints);
    }

    /// @notice Set the withdrawal cooldown duration.
    function setWithdrawalCooldown(uint256 seconds_) external onlyOwner {
        uint256 old = withdrawalCooldown;
        withdrawalCooldown = seconds_;
        emit WithdrawalCooldownUpdated(old, seconds_);
    }

    /// @notice Set the flat dispute bond amount for post-upgrade requests.
    function setDisputeBondAmount(uint256 amount) external onlyOwner {
        uint256 old = disputeBondAmount;
        disputeBondAmount = amount;
        emit DisputeBondAmountUpdated(old, amount);
    }

    /// @notice Set the stake token address.
    function setStakeToken(address token_) external onlyOwner {
        stakeToken = token_;
    }

    // ============ Agent Staking ============

    /// @notice Register as an agent with a stake.
    /// @param role The agent role (Info or Judge).
    function registerAgent(AgentRole role) external payable {
        if (agentStakes[msg.sender].registered) revert AlreadyRegistered(msg.sender);

        uint256 stakeAmount;
        if (stakeToken == address(0)) {
            stakeAmount = msg.value;
        } else {
            if (msg.value > 0) revert ETHSentWithERC20Bond();
            stakeAmount = minStakeAmount;
            IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);
        }

        if (stakeAmount < minStakeAmount) revert InsufficientStake(minStakeAmount, stakeAmount);

        agentStakes[msg.sender] =
            AgentStake({amount: stakeAmount, role: role, registered: true, withdrawRequestTime: 0});

        if (role == AgentRole.Info) {
            _registeredInfoAgents.push(msg.sender);
        } else {
            _registeredJudges.push(msg.sender);
        }

        emit AgentRegistered(msg.sender, role, stakeAmount);
    }

    /// @notice Add more stake to an existing registration.
    /// @param amount Amount to add (only used for ERC-20 stakeToken; for ETH, use msg.value).
    function addStake(uint256 amount) external payable {
        AgentStake storage stake = agentStakes[msg.sender];
        if (!stake.registered && stake.withdrawRequestTime == 0) revert NotRegistered(msg.sender);

        uint256 added;
        if (stakeToken == address(0)) {
            added = msg.value;
        } else {
            if (msg.value > 0) revert ETHSentWithERC20Bond();
            added = amount;
            IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), added);
        }

        stake.amount += added;
        emit StakeAdded(msg.sender, added, stake.amount);
    }

    /// @notice Request withdrawal of stake. Immediately removes from selection pool.
    function requestWithdrawal() external {
        AgentStake storage stake = agentStakes[msg.sender];
        if (!stake.registered) revert NotRegistered(msg.sender);
        if (stake.withdrawRequestTime != 0) revert WithdrawalAlreadyRequested(msg.sender);
        if (activeAssignments[msg.sender] > 0) {
            revert ActiveAssignmentsPending(msg.sender, activeAssignments[msg.sender]);
        }

        stake.withdrawRequestTime = block.timestamp;
        stake.registered = false;

        if (stake.role == AgentRole.Info) {
            _removeFromArray(_registeredInfoAgents, msg.sender);
        } else {
            _removeFromArray(_registeredJudges, msg.sender);
        }

        emit WithdrawalRequested(msg.sender, block.timestamp);
    }

    /// @notice Execute withdrawal after cooldown period.
    function executeWithdrawal() external {
        AgentStake storage stake = agentStakes[msg.sender];
        if (stake.withdrawRequestTime == 0) revert WithdrawalNotRequested(msg.sender);
        uint256 readyAt = stake.withdrawRequestTime + withdrawalCooldown;
        if (block.timestamp < readyAt) revert WithdrawalCooldownNotElapsed(msg.sender, readyAt);

        uint256 amount = stake.amount;
        stake.amount = 0;
        stake.withdrawRequestTime = 0;

        _transferToken(stakeToken, msg.sender, amount);

        emit WithdrawalExecuted(msg.sender, amount);
    }

    /// @notice Cancel a pending withdrawal and re-enter the pool.
    function cancelWithdrawal() external {
        AgentStake storage stake = agentStakes[msg.sender];
        if (stake.withdrawRequestTime == 0) revert WithdrawalNotRequested(msg.sender);
        if (stake.amount < minStakeAmount) revert StakeBelowMinimum(msg.sender, stake.amount, minStakeAmount);

        stake.withdrawRequestTime = 0;
        stake.registered = true;

        if (stake.role == AgentRole.Info) {
            _registeredInfoAgents.push(msg.sender);
        } else {
            _registeredJudges.push(msg.sender);
        }

        emit WithdrawalCancelled(msg.sender);
    }

    /// @notice Get all registered info agents.
    function getRegisteredInfoAgents() external view returns (address[] memory) {
        return _registeredInfoAgents;
    }

    /// @notice Get all registered judges.
    function getRegisteredJudges() external view returns (address[] memory) {
        return _registeredJudges;
    }

    /// @notice Get selected agents for a request.
    function getSelectedAgents(uint256 requestId) external view returns (address[] memory) {
        return _selectedAgents[requestId];
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

        bool isStakingModel = (bondAmount == 0);
        if (isStakingModel) {
            if (_registeredInfoAgents.length < numInfoAgents) {
                revert InsufficientRegisteredAgents(numInfoAgents, _registeredInfoAgents.length);
            }
            if (_registeredJudges.length == 0) revert NoJudgesAvailable();
            if (rewardToken != stakeToken) revert RewardTokenMustBeStakeToken(stakeToken, rewardToken);
        } else {
            if (_judgeList.length == 0) revert NoJudgesAvailable();
        }

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

        // Select agents if using staking model
        if (isStakingModel) {
            _selectInfoAgents(requestId, numInfoAgents);
        }

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

        bool isStakingModel = (req.bondAmount == 0);

        if (isStakingModel) {
            // Staking model: verify agent was selected
            bool selected = false;
            address[] storage selectedList = _selectedAgents[requestId];
            for (uint256 i; i < selectedList.length; ++i) {
                if (selectedList[i] == msg.sender) {
                    selected = true;
                    break;
                }
            }
            if (!selected) revert NotSelectedForRequest(requestId, msg.sender);
        } else {
            // Legacy bond model: collect bond
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
            // Slash all selected agents for not committing (staking model)
            if (req.bondAmount == 0) {
                address[] storage selected = _selectedAgents[requestId];
                for (uint256 i; i < selected.length; ++i) {
                    _slashAgentForRequest(requestId, selected[i]);
                    _decrementAssignment(selected[i]);
                }
            }
            // No agents committed — fail and refund requester
            phases[requestId] = Phase.Failed;
            _refundRequester(requestId);
            emit ResolutionFailed(requestId, "No agents committed");
            return;
        }

        // Slash non-committing selected agents (staking model only)
        if (req.bondAmount == 0) {
            address[] storage selected = _selectedAgents[requestId];
            for (uint256 i; i < selected.length; ++i) {
                bool didCommit = false;
                for (uint256 j; j < _committedAgents[requestId].length; ++j) {
                    if (selected[i] == _committedAgents[requestId][j]) {
                        didCommit = true;
                        break;
                    }
                }
                if (!didCommit) {
                    uint256 slashed = _slashAgentForRequest(requestId, selected[i]);
                    requestSlashedStake[requestId] += slashed;
                    _decrementAssignment(selected[i]);
                }
            }
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

        Request storage req = _requests[requestId];
        uint256 committed = _committedAgents[requestId].length;
        uint256 revealed = _revealedAgents[requestId].length;
        uint256 quorum = (committed / 2) + 1; // 50% + 1

        if (revealed < quorum) {
            phases[requestId] = Phase.Failed;
            _refundRequester(requestId);
            if (req.bondAmount == 0) {
                // Staking model: slash non-revealers, decrement all
                for (uint256 i; i < _committedAgents[requestId].length; ++i) {
                    address agent = _committedAgents[requestId][i];
                    if (!hasRevealed[requestId][agent]) {
                        _slashAgentForRequest(requestId, agent);
                    }
                    _decrementAssignment(agent);
                }
                // Also decrement non-committers among selected
                address[] storage selected = _selectedAgents[requestId];
                for (uint256 i; i < selected.length; ++i) {
                    bool didCommit = false;
                    for (uint256 j; j < _committedAgents[requestId].length; ++j) {
                        if (selected[i] == _committedAgents[requestId][j]) {
                            didCommit = true;
                            break;
                        }
                    }
                    if (!didCommit) _decrementAssignment(selected[i]);
                }
            } else {
                _refundRevealedAgentBonds(requestId);
            }
            emit ResolutionFailed(requestId, "Quorum not met");
            return;
        }

        // Slash non-revealers (staking model only)
        if (req.bondAmount == 0) {
            for (uint256 i; i < _committedAgents[requestId].length; ++i) {
                address agent = _committedAgents[requestId][i];
                if (!hasRevealed[requestId][agent]) {
                    uint256 slashed = _slashAgentForRequest(requestId, agent);
                    requestSlashedStake[requestId] += slashed;
                    _decrementAssignment(agent);
                }
            }
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
        if (winners.length > 0) {
            // Validate all winners actually revealed
            for (uint256 i; i < winners.length; ++i) {
                if (!hasRevealed[requestId][winners[i]]) {
                    revert WinnerNotRevealed(requestId, winners[i]);
                }
            }
        }

        _finalAnswers[requestId] = finalAnswer;
        _reasoning[requestId] = reasoning;
        _winners[requestId] = winners;

        // Slash losers (staking model only, only if there are winners)
        Request storage req = _requests[requestId];
        if (req.bondAmount == 0 && winners.length > 0) {
            for (uint256 i; i < _revealedAgents[requestId].length; ++i) {
                address agent = _revealedAgents[requestId][i];
                bool isWinner = false;
                for (uint256 j; j < winners.length; ++j) {
                    if (agent == winners[j]) {
                        isWinner = true;
                        break;
                    }
                }
                if (!isWinner) {
                    uint256 slashed = _slashAgentForRequest(requestId, agent);
                    requestSlashedStake[requestId] += slashed;
                }
            }
        }

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp + _effectiveDisputeWindow(requestId);

        emit ResolutionFinalized(requestId, finalAnswer);
        emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
    }

    /// @inheritdoc IAgentCouncilOracle
    function distributeRewards(uint256 requestId) external nonReentrant {
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
        bool isStakingModel = (req.bondAmount == 0);

        if (isStakingModel) {
            // Execute deferred judge slash (if any, and only if there are winners)
            if (judgeToSlash[requestId] != address(0) && numWinners > 0) {
                uint256 judgeSlashed = _slashAgent(judgeToSlash[requestId]);
                uint256 beneficiaryShare = judgeSlashed / 2;
                _transferToken(stakeToken, slashBeneficiary[requestId], beneficiaryShare);
                requestSlashedStake[requestId] += (judgeSlashed - beneficiaryShare);
                emit JudgeSlashed(requestId, judgeToSlash[requestId], judgeSlashed, slashBeneficiary[requestId]);
            }

            if (numWinners == 0) {
                // Inconclusive — refund everything
                _refundRequester(requestId);

                // Restore slashed agent stakes
                address[] storage slashedList = _slashedAgents[requestId];
                for (uint256 i; i < slashedList.length; ++i) {
                    address agent = slashedList[i];
                    uint256 restoreAmount = _slashedAmounts[requestId][agent];
                    if (restoreAmount > 0) {
                        agentStakes[agent].amount += restoreAmount;
                        // Re-register if eligible
                        if (
                            agentStakes[agent].amount >= minStakeAmount && !agentStakes[agent].registered
                                && agentStakes[agent].withdrawRequestTime == 0
                        ) {
                            agentStakes[agent].registered = true;
                            if (agentStakes[agent].role == AgentRole.Info) {
                                _registeredInfoAgents.push(agent);
                            } else {
                                _registeredJudges.push(agent);
                            }
                        }
                        emit StakeRestored(agent, restoreAmount);
                    }
                }

                // Return dispute bond if used
                if (disputeUsed[requestId] && disputeBondPaid[requestId] > 0) {
                    _transferToken(stakeToken, disputer[requestId], disputeBondPaid[requestId]);
                }

                // Return DAO escalation bond if used
                if (daoEscalationUsed[requestId] && daoEscalationBondPaid[requestId] > 0) {
                    IERC20(daoEscalationBondToken)
                        .safeTransfer(daoEscalator[requestId], daoEscalationBondPaid[requestId]);
                }

                // Decrement active assignments for all revealed agents
                for (uint256 i; i < _revealedAgents[requestId].length; ++i) {
                    _decrementAssignment(_revealedAgents[requestId][i]);
                }

                phases[requestId] = Phase.Failed;
                emit InconclusiveResolution(requestId);
            } else {
                // Normal distribution with winners
                uint256 rewardPerWinner = req.rewardAmount / numWinners;
                uint256 totalSlashed = requestSlashedStake[requestId];
                uint256 slashPerWinner = numWinners > 0 ? totalSlashed / numWinners : 0;

                address[] memory winnerList = new address[](numWinners);
                uint256[] memory amounts = new uint256[](numWinners);

                for (uint256 i; i < numWinners; ++i) {
                    address winner = winners[i];
                    winnerList[i] = winner;

                    uint256 totalPayout = rewardPerWinner + slashPerWinner;
                    // Add rewards to winner's staking pool (auto-compound)
                    agentStakes[winner].amount += totalPayout;
                    amounts[i] = totalPayout;
                }

                // Decrement activeAssignments for revealed agents only.
                for (uint256 i; i < _revealedAgents[requestId].length; ++i) {
                    _decrementAssignment(_revealedAgents[requestId][i]);
                }

                phases[requestId] = Phase.Distributed;
                emit RewardsDistributed(requestId, winnerList, amounts);
            }
        } else {
            // Legacy bond model (existing logic)
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
    }

    // ============ Dispute Functions ============

    /// @notice File a dispute against the judge's decision.
    /// @param requestId The request to dispute.
    /// @param reason On-chain reason or IPFS hash of detailed reasoning.
    function initiateDispute(uint256 requestId, string calldata reason) external payable nonReentrant {
        _requirePhase(requestId, Phase.DisputeWindow);
        if (block.timestamp >= disputeWindowEnd[requestId]) revert DisputeWindowNotOpen(requestId);
        if (disputeUsed[requestId]) revert DisputeAlreadyUsed(requestId);

        Request storage req = _requests[requestId];
        uint256 requiredBond;
        if (req.bondAmount == 0) {
            // Staking model: use flat dispute bond
            requiredBond = disputeBondAmount;
        } else {
            // Legacy: bondAmount * multiplier
            requiredBond = req.bondAmount * disputeBondMultiplier / 100;
        }

        if (req.bondAmount == 0) {
            // Staking model: collect dispute bond in stakeToken
            if (msg.value > 0) revert ETHSentWithERC20Bond();
            IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), requiredBond);
        } else if (req.bondToken == address(0)) {
            // Legacy ETH bond
            if (msg.value < requiredBond) revert InsufficientDisputeBond(requiredBond, msg.value);
            uint256 excess = msg.value - requiredBond;
            if (excess > 0) {
                (bool ok,) = msg.sender.call{value: excess}("");
                if (!ok) revert TransferFailed();
            }
        } else {
            // Legacy ERC-20 bond
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
    function resolveDispute(uint256 requestId, bool overturn, bytes calldata newAnswer, address[] calldata newWinners)
        external
        nonReentrant
    {
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

            address disputeToken = req.bondAmount == 0 ? stakeToken : req.bondToken;
            _transferToken(disputeToken, disputer[requestId], bondAmount);

            _finalAnswers[requestId] = newAnswer;
            _winners[requestId] = newWinners;

            // Track original judge for slashing at distribution time
            judgeToSlash[requestId] = selectedJudge[requestId];
            slashBeneficiary[requestId] = disputer[requestId];
        } else {
            address disputeToken = req.bondAmount == 0 ? stakeToken : req.bondToken;
            _distributeForfeitedBond(requestId, disputeToken, bondAmount, req.requester);

            // Judge was right — clear any slash target
            judgeToSlash[requestId] = address(0);
            slashBeneficiary[requestId] = address(0);
        }

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp + _effectiveDisputeWindow(requestId);

        emit DisputeResolved(requestId, overturn, _finalAnswers[requestId]);
        emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
    }

    /// @notice Escalate to DAO after dispute resolution, or directly if only 1 judge exists.
    /// @param requestId The request to escalate.
    function initiateDAOEscalation(uint256 requestId) external {
        _requirePhase(requestId, Phase.DisputeWindow);
        if (block.timestamp >= disputeWindowEnd[requestId]) revert DisputeWindowNotOpen(requestId);
        // Allow direct DAO escalation if only 1 judge (can't dispute — no alternative judge)
        Request storage req = _requests[requestId];
        bool isStakingModel = (req.bondAmount == 0);
        uint256 judgeCount = isStakingModel ? _registeredJudges.length : _judgeList.length;
        if (!disputeUsed[requestId] && judgeCount > 1) revert DisputeRequired(requestId);
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
    /// @param outcome 0 = uphold, 1 = overturn, 2 = inconclusive.
    /// @param newAnswer New final answer (only used if outcome=1).
    /// @param newWinners New winners (only used if outcome=1).
    function resolveDAOEscalation(
        uint256 requestId,
        uint8 outcome,
        bytes calldata newAnswer,
        address[] calldata newWinners
    ) external nonReentrant {
        _requirePhase(requestId, Phase.DAOEscalation);
        if (msg.sender != daoAddress) revert NotDAO(msg.sender);
        if (block.timestamp > daoEscalationDeadline[requestId]) revert DAOResolutionTimedOut(requestId);
        if (outcome > 2) revert InvalidDAOOutcome(outcome);

        uint256 bondAmount = daoEscalationBondPaid[requestId];

        if (outcome == 1) {
            // Overturn
            if (newWinners.length == 0) revert NoWinners();
            for (uint256 i; i < newWinners.length; ++i) {
                if (!hasRevealed[requestId][newWinners[i]]) {
                    revert WinnerNotRevealed(requestId, newWinners[i]);
                }
            }

            IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], bondAmount);

            _finalAnswers[requestId] = newAnswer;
            _winners[requestId] = newWinners;

            // Slash dispute judge (who made the wrong call)
            judgeToSlash[requestId] = disputeJudge[requestId];
            slashBeneficiary[requestId] = daoEscalator[requestId];
        } else if (outcome == 0) {
            // Uphold
            Request storage req = _requests[requestId];
            _distributeForfeitedBond(requestId, daoEscalationBondToken, bondAmount, req.requester);

            // If judgeToSlash was set from a prior dispute overturn, keep it
            // Set beneficiary to escalator if not already set
            if (slashBeneficiary[requestId] == address(0)) {
                slashBeneficiary[requestId] = daoEscalator[requestId];
            }
        } else {
            // Inconclusive (outcome == 2)
            IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], bondAmount);

            // Clear winners to signal inconclusive
            delete _winners[requestId];

            // No judge slash on inconclusive
            judgeToSlash[requestId] = address(0);
            slashBeneficiary[requestId] = address(0);
        }

        phases[requestId] = Phase.DisputeWindow;
        disputeWindowEnd[requestId] = block.timestamp;

        emit DAOEscalationResolved(requestId, _finalAnswers[requestId]);
    }

    /// @notice Timeout a DAO escalation if the DAO fails to act.
    ///         Anyone can call after the deadline passes.
    /// @param requestId The escalated request.
    function timeoutDAOEscalation(uint256 requestId) external nonReentrant {
        _requirePhase(requestId, Phase.DAOEscalation);
        if (block.timestamp <= daoEscalationDeadline[requestId]) revert DAODeadlineNotPassed(requestId);

        IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], daoEscalationBondPaid[requestId]);

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

    /// @dev Returns the effective dispute window for a request (per-request override or global default).
    function _effectiveDisputeWindow(uint256 requestId) internal view returns (uint256) {
        uint256 perRequest = requestDisputeWindow[requestId];
        return perRequest > 0 ? perRequest : disputeWindow;
    }

    function _transitionToJudging(uint256 requestId) internal {
        Request storage req = _requests[requestId];
        bool isStakingModel = (req.bondAmount == 0);

        address[] storage judgePool;
        if (isStakingModel) {
            judgePool = _registeredJudges;
        } else {
            judgePool = _judgeList;
        }

        uint256 judgeCount = judgePool.length;
        if (judgeCount == 0) revert NoJudgesAvailable();

        uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId)));
        address judge = judgePool[seed % judgeCount];

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
    function _distributeForfeitedBond(uint256 requestId, address token_, uint256 bondAmount, address requesterAddr)
        internal
    {
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
        Request storage req = _requests[requestId];
        bool isStakingModel = (req.bondAmount == 0);

        address[] storage judgePool;
        if (isStakingModel) {
            judgePool = _registeredJudges;
        } else {
            judgePool = _judgeList;
        }
        uint256 judgeCount = judgePool.length;

        uint256 eligible = 0;
        for (uint256 i; i < judgeCount; ++i) {
            if (judgePool[i] != originalJudge) eligible++;
        }
        if (eligible == 0) revert NoDisputeJudgeAvailable(requestId);

        uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId, "dispute")));
        uint256 pick = seed % eligible;

        uint256 count = 0;
        for (uint256 i; i < judgeCount; ++i) {
            if (judgePool[i] != originalJudge) {
                if (count == pick) {
                    disputeJudge[requestId] = judgePool[i];
                    return;
                }
                count++;
            }
        }
    }

    /// @dev Pseudo-randomly select N info agents from the registered pool.
    function _selectInfoAgents(uint256 requestId, uint256 count) internal {
        uint256 poolSize = _registeredInfoAgents.length;

        // Copy pool to memory for Fisher-Yates shuffle
        address[] memory pool = new address[](poolSize);
        for (uint256 i; i < poolSize; ++i) {
            pool[i] = _registeredInfoAgents[i];
        }

        for (uint256 i; i < count; ++i) {
            uint256 remaining = poolSize - i;
            uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId, i)));
            uint256 pick = i + (seed % remaining);

            // Swap picked element to position i
            address temp = pool[i];
            pool[i] = pool[pick];
            pool[pick] = temp;

            _selectedAgents[requestId].push(pool[i]);
            activeAssignments[pool[i]] += 1;
            emit AgentSelected(requestId, pool[i]);
        }
    }

    /// @dev Slash an agent's stake by slashPercentage. Returns the slashed amount.
    function _slashAgent(address agent) internal returns (uint256 slashed) {
        AgentStake storage stake = agentStakes[agent];
        if (stake.amount == 0) return 0;

        slashed = stake.amount * slashPercentage / 10000;
        stake.amount -= slashed;

        emit AgentSlashed(agent, slashed, stake.amount);

        // Auto-deregister if below minimum
        if (stake.amount < minStakeAmount && stake.registered) {
            stake.registered = false;
            if (stake.role == AgentRole.Info) {
                _removeFromArray(_registeredInfoAgents, agent);
            } else {
                _removeFromArray(_registeredJudges, agent);
            }
            emit AgentDeregistered(agent);
        }

        return slashed;
    }

    /// @dev Slash an agent and record it per-request for potential restore.
    function _slashAgentForRequest(uint256 requestId, address agent) internal returns (uint256 slashed) {
        slashed = _slashAgent(agent);
        if (slashed > 0) {
            _slashedAgents[requestId].push(agent);
            _slashedAmounts[requestId][agent] += slashed;
        }
    }

    /// @dev Decrement active assignments for an agent.
    function _decrementAssignment(address agent) internal {
        if (activeAssignments[agent] > 0) {
            activeAssignments[agent] -= 1;
        }
    }

    /// @dev Remove an address from a dynamic array by swapping with last element.
    function _removeFromArray(address[] storage arr, address addr) internal {
        uint256 len = arr.length;
        for (uint256 i; i < len; ++i) {
            if (arr[i] == addr) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @notice UUPS authorization — only owner can upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
