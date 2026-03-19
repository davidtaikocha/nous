// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {NousOracle} from "../src/NousOracle.sol";
import {IAgentCouncilOracle} from "../src/IAgentCouncilOracle.sol";

/// @dev Simple ERC20 token for testing.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NousOracleTest is Test {
    NousOracle public oracle;
    MockERC20 public token;

    address owner = makeAddr("owner");
    address requester = makeAddr("requester");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");
    address judge1 = makeAddr("judge1");
    address judge2 = makeAddr("judge2");

    uint256 constant REVEAL_DURATION = 1 hours;
    uint256 constant REWARD = 1 ether;
    uint256 constant BOND = 0.1 ether;

    function setUp() public {
        // Deploy implementation + proxy
        NousOracle impl = new NousOracle();
        bytes memory initData = abi.encodeCall(NousOracle.initialize, (owner, REVEAL_DURATION));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oracle = NousOracle(address(proxy));

        // Deploy mock token
        token = new MockERC20();

        // Setup judges
        vm.startPrank(owner);
        oracle.addJudge(judge1);
        oracle.addJudge(judge2);
        vm.stopPrank();

        // Fund accounts
        vm.deal(requester, 100 ether);
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(agent3, 10 ether);
    }

    // ============ Helpers ============

    function _defaultCapabilities() internal pure returns (IAgentCouncilOracle.AgentCapabilities memory) {
        string[] memory caps = new string[](1);
        caps[0] = "text";
        string[] memory domains = new string[](1);
        domains[0] = "general";
        return IAgentCouncilOracle.AgentCapabilities(caps, domains);
    }

    function _createDefaultRequest() internal returns (uint256) {
        return _createDefaultRequest(2);
    }

    function _createDefaultRequest(uint256 numAgents) internal returns (uint256) {
        vm.prank(requester);
        return oracle.createRequest{value: REWARD}(
            "What is the weather in Tokyo?",
            numAgents,
            REWARD,
            BOND,
            block.timestamp + 1 hours,
            address(0), // native ETH reward
            address(0), // native ETH bond
            "Return JSON with temperature and conditions",
            _defaultCapabilities()
        );
    }

    function _commitAgent(uint256 requestId, address agent, bytes memory answer, uint256 nonce) internal {
        bytes32 commitment = keccak256(abi.encode(answer, nonce));
        vm.prank(agent);
        oracle.commit{value: BOND}(requestId, commitment);
    }

    function _revealAgent(uint256 requestId, address agent, bytes memory answer, uint256 nonce) internal {
        vm.prank(agent);
        oracle.reveal(requestId, answer, nonce);
    }

    // ============ Initialization Tests ============

    function test_initialize() public view {
        assertEq(oracle.owner(), owner);
        assertEq(oracle.revealDuration(), REVEAL_DURATION);
        assertEq(oracle.nextRequestId(), 1);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        oracle.initialize(owner, REVEAL_DURATION);
    }

    // ============ Judge Management Tests ============

    function test_addJudge() public view {
        assertTrue(oracle.isApprovedJudge(judge1));
        assertTrue(oracle.isApprovedJudge(judge2));

        address[] memory judges = oracle.getJudges();
        assertEq(judges.length, 2);
    }

    function test_removeJudge() public {
        vm.prank(owner);
        oracle.removeJudge(judge1);

        assertFalse(oracle.isApprovedJudge(judge1));
        address[] memory judges = oracle.getJudges();
        assertEq(judges.length, 1);
        assertEq(judges[0], judge2);
    }

    function test_onlyOwnerCanManageJudges() public {
        vm.prank(agent1);
        vm.expectRevert();
        oracle.addJudge(agent1);
    }

    // ============ createRequest Tests ============

    function test_createRequest_native() public {
        uint256 requestId = _createDefaultRequest();

        assertEq(requestId, 1);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Committing));

        IAgentCouncilOracle.Request memory req = oracle.getRequest(requestId);
        assertEq(req.requester, requester);
        assertEq(req.rewardAmount, REWARD);
        assertEq(req.bondAmount, BOND);
        assertEq(req.numInfoAgents, 2);
    }

    function test_createRequest_erc20() public {
        token.mint(requester, 10 ether);

        vm.startPrank(requester);
        token.approve(address(oracle), REWARD);
        uint256 requestId = oracle.createRequest(
            "Test query",
            2,
            REWARD,
            BOND,
            block.timestamp + 1 hours,
            address(token), // ERC20 reward
            address(0), // native bond
            "",
            _defaultCapabilities()
        );
        vm.stopPrank();

        IAgentCouncilOracle.Request memory req = oracle.getRequest(requestId);
        assertEq(req.rewardToken, address(token));
        assertEq(token.balanceOf(address(oracle)), REWARD);
    }

    function test_createRequest_refundsExcess() public {
        uint256 balanceBefore = requester.balance;

        vm.prank(requester);
        oracle.createRequest{value: 2 ether}(
            "Test", 2, REWARD, BOND, block.timestamp + 1 hours, address(0), address(0), "", _defaultCapabilities()
        );

        // Should have refunded 1 ether
        assertEq(requester.balance, balanceBefore - REWARD);
    }

    function test_createRequest_revertsIfDeadlineInPast() public {
        vm.prank(requester);
        vm.expectRevert(NousOracle.DeadlineMustBeFuture.selector);
        oracle.createRequest{value: REWARD}(
            "Test", 2, REWARD, BOND, block.timestamp - 1, address(0), address(0), "", _defaultCapabilities()
        );
    }

    function test_createRequest_revertsIfNoJudges() public {
        // Remove all judges
        vm.startPrank(owner);
        oracle.removeJudge(judge1);
        oracle.removeJudge(judge2);
        vm.stopPrank();

        vm.prank(requester);
        vm.expectRevert(NousOracle.NoJudgesAvailable.selector);
        oracle.createRequest{value: REWARD}(
            "Test", 2, REWARD, BOND, block.timestamp + 1 hours, address(0), address(0), "", _defaultCapabilities()
        );
    }

    // ============ Commit Tests ============

    function test_commit() public {
        uint256 requestId = _createDefaultRequest();

        bytes memory answer = abi.encode("sunny, 22C");
        _commitAgent(requestId, agent1, answer, 123);

        (address[] memory agents, bytes32[] memory hashes) = oracle.getCommits(requestId);
        assertEq(agents.length, 1);
        assertEq(agents[0], agent1);
        assertEq(hashes[0], keccak256(abi.encode(answer, uint256(123))));
    }

    function test_commit_autoTransitionsToRevealing() public {
        uint256 requestId = _createDefaultRequest(2);

        _commitAgent(requestId, agent1, abi.encode("answer1"), 1);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Committing));

        _commitAgent(requestId, agent2, abi.encode("answer2"), 2);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Revealing));
    }

    function test_commit_revertsIfAlreadyCommitted() public {
        uint256 requestId = _createDefaultRequest();

        _commitAgent(requestId, agent1, abi.encode("answer"), 1);

        vm.expectRevert(abi.encodeWithSelector(NousOracle.AlreadyCommitted.selector, requestId, agent1));
        _commitAgent(requestId, agent1, abi.encode("answer2"), 2);
    }

    function test_commit_revertsIfMaxAgentsReached() public {
        uint256 requestId = _createDefaultRequest(2);

        _commitAgent(requestId, agent1, abi.encode("a1"), 1);
        _commitAgent(requestId, agent2, abi.encode("a2"), 2);
        // Phase auto-transitioned to Revealing, so 3rd commit gets InvalidPhase
        vm.expectRevert(
            abi.encodeWithSelector(
                NousOracle.InvalidPhase.selector, requestId, NousOracle.Phase.Committing, NousOracle.Phase.Revealing
            )
        );
        _commitAgent(requestId, agent3, abi.encode("a3"), 3);
    }

    function test_commit_revertsAfterDeadline() public {
        uint256 requestId = _createDefaultRequest();

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(NousOracle.DeadlinePassed.selector);
        _commitAgent(requestId, agent1, abi.encode("answer"), 1);
    }

    // ============ endCommitPhase Tests ============

    function test_endCommitPhase_noAgents() public {
        uint256 requestId = _createDefaultRequest();

        vm.warp(block.timestamp + 2 hours);
        oracle.endCommitPhase(requestId);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Failed));
        // Requester should have been refunded
        assertEq(requester.balance, 100 ether);
    }

    function test_endCommitPhase_partialCommits() public {
        uint256 requestId = _createDefaultRequest(3);

        _commitAgent(requestId, agent1, abi.encode("a1"), 1);

        vm.warp(block.timestamp + 2 hours);
        oracle.endCommitPhase(requestId);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Revealing));
    }

    // ============ Reveal Tests ============

    function test_reveal() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory answer1 = abi.encode("sunny, 22C");
        bytes memory answer2 = abi.encode("cloudy, 20C");

        _commitAgent(requestId, agent1, answer1, 100);
        _commitAgent(requestId, agent2, answer2, 200);
        // Phase is now Revealing

        _revealAgent(requestId, agent1, answer1, 100);

        (address[] memory agents, bytes[] memory answers) = oracle.getReveals(requestId);
        assertEq(agents.length, 1);
        assertEq(agents[0], agent1);
        assertEq(answers[0], answer1);
    }

    function test_reveal_revertsOnMismatch() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory answer = abi.encode("sunny");
        _commitAgent(requestId, agent1, answer, 100);
        _commitAgent(requestId, agent2, abi.encode("cloudy"), 200);

        vm.expectRevert(abi.encodeWithSelector(NousOracle.CommitmentMismatch.selector, requestId, agent1));
        _revealAgent(requestId, agent1, abi.encode("different answer"), 100);
    }

    function test_reveal_autoTransitionsToJudging() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory answer1 = abi.encode("sunny");
        bytes memory answer2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, answer1, 1);
        _commitAgent(requestId, agent2, answer2, 2);

        _revealAgent(requestId, agent1, answer1, 1);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Revealing));

        _revealAgent(requestId, agent2, answer2, 2);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Judging));

        // A judge should be selected
        address judge = oracle.selectedJudge(requestId);
        assertTrue(judge == judge1 || judge == judge2);
    }

    // ============ endRevealPhase Tests ============

    function test_endRevealPhase_quorumMet() public {
        uint256 requestId = _createDefaultRequest(3);

        bytes memory a1 = abi.encode("a1");
        bytes memory a2 = abi.encode("a2");
        bytes memory a3 = abi.encode("a3");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _commitAgent(requestId, agent3, a3, 3);
        // Auto-transitioned to Revealing (3/3 agents committed)

        // Only agent1 and agent2 reveal (2 out of 3 committed = quorum of 2 met)
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        // End reveal phase after deadline
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.endRevealPhase(requestId);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Judging));
    }

    function test_endRevealPhase_quorumNotMet() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("a1");
        bytes memory a2 = abi.encode("a2");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        // Auto-transitioned to Revealing

        // Nobody reveals. End reveal phase.
        vm.warp(block.timestamp + REVEAL_DURATION + 1);
        oracle.endRevealPhase(requestId);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Failed));
        // Requester refunded
        assertEq(requester.balance, 100 ether);
    }

    // ============ Aggregate Tests ============

    function test_aggregate() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);
        // Now in Judging phase

        address judge = oracle.selectedJudge(requestId);

        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny, final"), winners, abi.encode("agent1 was more accurate"));

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Finalized));

        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        assertTrue(finalized);
        assertEq(finalAnswer, abi.encode("sunny, final"));
    }

    function test_aggregate_revertsIfNotJudge() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(agent1); // not the judge
        vm.expectRevert(abi.encodeWithSelector(NousOracle.NotSelectedJudge.selector, requestId, agent1));
        oracle.aggregate(requestId, abi.encode("answer"), winners, abi.encode("reasoning"));
    }

    // ============ distributeRewards Tests ============

    function test_distributeRewards_singleWinner() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("correct"));

        uint256 agent1BalBefore = agent1.balance;
        uint256 agent2BalBefore = agent2.balance;

        oracle.distributeRewards(requestId);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));

        // agent1 gets: reward (1 ETH) + bond back (0.1 ETH) + slashed bond from agent2 (0.1 ETH)
        assertEq(agent1.balance, agent1BalBefore + REWARD + BOND + BOND);
        // agent2 gets nothing (bond was slashed)
        assertEq(agent2.balance, agent2BalBefore);
    }

    function test_distributeRewards_multipleWinners() public {
        uint256 requestId = _createDefaultRequest(3);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("sunny too");
        bytes memory a3 = abi.encode("rainy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _commitAgent(requestId, agent3, a3, 3);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent3, a3, 3);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](2);
        winners[0] = agent1;
        winners[1] = agent2;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny consensus"), winners, abi.encode("two agreed"));

        uint256 agent1Bal = agent1.balance;
        uint256 agent2Bal = agent2.balance;

        oracle.distributeRewards(requestId);

        // Each winner gets: reward/2 + bond back + slashed/2
        uint256 expectedReward = REWARD / 2;
        uint256 expectedSlash = BOND / 2; // 1 loser, split among 2
        uint256 expectedTotal = expectedReward + BOND + expectedSlash;

        assertEq(agent1.balance, agent1Bal + expectedTotal);
        assertEq(agent2.balance, agent2Bal + expectedTotal);
    }

    function test_distributeRewards_erc20() public {
        // Setup ERC20 request
        token.mint(requester, 10 ether);
        token.mint(agent1, 10 ether);
        token.mint(agent2, 10 ether);

        vm.prank(requester);
        token.approve(address(oracle), REWARD);

        vm.prank(requester);
        uint256 requestId = oracle.createRequest(
            "Test",
            2,
            REWARD,
            BOND,
            block.timestamp + 1 hours,
            address(token), // ERC20 reward
            address(0), // native bond
            "",
            _defaultCapabilities()
        );

        bytes memory a1 = abi.encode("answer1");
        bytes memory a2 = abi.encode("answer2");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("final"), winners, abi.encode("r"));

        uint256 agent1TokenBal = token.balanceOf(agent1);

        oracle.distributeRewards(requestId);

        // agent1 gets REWARD in ERC20
        assertEq(token.balanceOf(agent1), agent1TokenBal + REWARD);
    }

    // ============ Full Flow E2E Test ============

    function test_fullFlow() public {
        // 1. Create request
        uint256 requestId = _createDefaultRequest(2);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Committing));

        // 2. Agents commit
        bytes memory answer1 = abi.encode("Tokyo: sunny, 22C, wind 5km/h");
        bytes memory answer2 = abi.encode("Tokyo: partly cloudy, 21C, wind 8km/h");

        _commitAgent(requestId, agent1, answer1, 42);
        _commitAgent(requestId, agent2, answer2, 99);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Revealing));

        // 3. Agents reveal
        _revealAgent(requestId, agent1, answer1, 42);
        _revealAgent(requestId, agent2, answer2, 99);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Judging));

        // 4. Judge aggregates
        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](2);
        winners[0] = agent1;
        winners[1] = agent2;

        vm.prank(judge);
        oracle.aggregate(
            requestId,
            abi.encode('{"condition":"sunny","temp":22,"wind":6}'),
            winners,
            abi.encode("Both agents provided consistent data, averaged wind speed")
        );
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Finalized));

        // 5. Check resolution
        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        assertTrue(finalized);
        assertGt(finalAnswer.length, 0);

        // 6. Distribute rewards
        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    }

    // ============ View Function Tests ============

    function test_getResolution_notFinalized() public {
        uint256 requestId = _createDefaultRequest();

        (bytes memory answer, bool finalized) = oracle.getResolution(requestId);
        assertFalse(finalized);
        assertEq(answer.length, 0);
    }

    function test_getWinnersAndReasoning() public {
        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("a1");
        bytes memory a2 = abi.encode("a2");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;
        bytes memory reasoning = abi.encode("agent1 was correct");

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("final"), winners, reasoning);

        address[] memory storedWinners = oracle.getWinners(requestId);
        assertEq(storedWinners.length, 1);
        assertEq(storedWinners[0], agent1);

        bytes memory storedReasoning = oracle.getReasoning(requestId);
        assertEq(storedReasoning, reasoning);
    }

    // ============ Dispute: Modified Existing Behavior ============

    function test_aggregate_transitionsToDisputeWindow() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny, final"), winners, abi.encode("agent1 was more accurate"));

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
        assertGt(oracle.disputeWindowEnd(requestId), block.timestamp);
    }

    function test_distributeRewards_requiresDisputeWindowExpired() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("correct"));

        vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeWindowNotExpired.selector, requestId));
        oracle.distributeRewards(requestId);

        vm.warp(block.timestamp + 1 hours + 1);
        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    }
}
