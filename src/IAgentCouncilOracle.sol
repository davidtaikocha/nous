// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IAgentCouncilOracle
/// @notice ERC-8033: Standardized interface for oracle contracts utilizing
///         multi-agent councils to resolve arbitrary information queries.
interface IAgentCouncilOracle {
    // ============ Data Structures ============

    struct AgentCapabilities {
        string[] capabilities; // e.g., "text", "vision", "audio"
        string[] domains; // expertise areas
    }

    struct Request {
        address requester;
        uint256 rewardAmount;
        address rewardToken; // address(0) for native ETH
        uint256 bondAmount;
        address bondToken; // address(0) for native ETH
        uint256 numInfoAgents;
        uint256 deadline; // Unix timestamp for commit phase end
        string query;
        string specifications;
        AgentCapabilities requiredCapabilities;
    }

    // ============ Events ============

    event RequestCreated(
        uint256 indexed requestId,
        address requester,
        string query,
        uint256 rewardAmount,
        uint256 numInfoAgents,
        uint256 bondAmount
    );

    event AgentCommitted(uint256 indexed requestId, address agent, bytes32 commitment);

    event AgentRevealed(uint256 indexed requestId, address agent, bytes answer);

    event JudgeSelected(uint256 indexed requestId, address judge);

    event ResolutionFinalized(uint256 indexed requestId, bytes finalAnswer);

    event RewardsDistributed(uint256 indexed requestId, address[] winners, uint256[] amounts);

    event ResolutionFailed(uint256 indexed requestId, string reason);

    // ============ Core Functions ============

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
    ) external payable returns (uint256 requestId);

    function commit(uint256 requestId, bytes32 commitment) external payable;

    function reveal(uint256 requestId, bytes calldata answer, uint256 nonce) external;

    function aggregate(
        uint256 requestId,
        bytes calldata finalAnswer,
        address[] calldata winners,
        bytes calldata reasoning
    ) external;

    function distributeRewards(uint256 requestId) external;

    function getResolution(uint256 requestId)
        external
        view
        returns (bytes memory finalAnswer, bool finalized);

    // ============ Getters ============

    function getRequest(uint256 requestId) external view returns (Request memory);

    function getCommits(uint256 requestId)
        external
        view
        returns (address[] memory agents, bytes32[] memory commitments);

    function getReveals(uint256 requestId)
        external
        view
        returns (address[] memory agents, bytes[] memory answers);
}
