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
    uint256 constant MIN_STAKE = 0.5 ether;
    uint256 constant SLASH_PCT = 5000; // 50% in basis points
    uint256 constant WITHDRAW_COOLDOWN = 1 days;

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

    function _setupStaking() internal {
        vm.startPrank(owner);
        oracle.setMinStakeAmount(MIN_STAKE);
        oracle.setSlashPercentage(SLASH_PCT);
        oracle.setWithdrawalCooldown(WITHDRAW_COOLDOWN);
        vm.stopPrank();
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

    function _driveToDisputed(uint256 requestId) internal returns (address originalJudge) {
        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        _commitAgent(requestId, agent1, a1, 1);
        _commitAgent(requestId, agent2, a2, 2);
        _revealAgent(requestId, agent1, a1, 1);
        _revealAgent(requestId, agent2, a2, 2);

        originalJudge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(originalJudge);
        oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("correct"));

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "Disagree");
    }

    function _driveToDAOEscalation(uint256 requestId) internal returns (address dao, MockERC20 taikoToken) {
        dao = makeAddr("dao");
        taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        oracle.setDaoResolutionWindow(7 days);
        vm.stopPrank();

        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        vm.prank(dJudge);
        oracle.resolveDispute(requestId, false, "", new address[](0));

        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);
        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();
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

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        assertFalse(finalized);
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

        vm.warp(block.timestamp + oracle.disputeWindow() + 1);

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

        vm.warp(block.timestamp + oracle.disputeWindow() + 1);

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

        vm.warp(block.timestamp + oracle.disputeWindow() + 1);

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
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        // 5. Check resolution
        (bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
        assertFalse(finalized);
        assertGt(finalAnswer.length, 0);

        // 6. Distribute rewards
        vm.warp(block.timestamp + oracle.disputeWindow() + 1);
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

    // ============ Dispute: initiateDispute Tests ============

    function test_initiateDispute() public {
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

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "Judge was wrong");

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Disputed));
        assertTrue(oracle.disputeUsed(requestId));
        assertEq(oracle.disputer(requestId), disputerAddr);
        assertEq(oracle.disputeBondPaid(requestId), disputeBondRequired);

        address dJudge = oracle.disputeJudge(requestId);
        assertTrue(dJudge != address(0));
        assertTrue(dJudge != judge);
    }

    function test_initiateDispute_revertsAfterWindow() public {
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

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeWindowNotOpen.selector, requestId));
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "Too late");
    }

    function test_initiateDispute_revertsIfAlreadyUsed() public {
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

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "First dispute");

        address disputer2 = makeAddr("disputer2");
        vm.deal(disputer2, 1 ether);
        vm.prank(disputer2);
        vm.expectRevert();
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "Second dispute");
    }

    function test_initiateDispute_revertsIfNoOtherJudge() public {
        vm.startPrank(owner);
        oracle.removeJudge(judge2);
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

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.NoDisputeJudgeAvailable.selector, requestId));
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "No other judge");
    }

    function test_initiateDispute_revertsETHWithERC20Bond() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        token.mint(requester, 10 ether);
        token.mint(agent1, 10 ether);
        token.mint(agent2, 10 ether);

        vm.prank(requester);
        token.approve(address(oracle), REWARD);

        vm.prank(agent1);
        token.approve(address(oracle), BOND);
        vm.prank(agent2);
        token.approve(address(oracle), BOND);

        vm.prank(requester);
        uint256 requestId = oracle.createRequest(
            "Test", 2, REWARD, BOND, block.timestamp + 1 hours,
            address(token), address(token), "", _defaultCapabilities()
        );

        bytes memory a1 = abi.encode("sunny");
        bytes memory a2 = abi.encode("cloudy");

        bytes32 c1 = keccak256(abi.encode(a1, uint256(1)));
        bytes32 c2 = keccak256(abi.encode(a2, uint256(2)));

        vm.prank(agent1);
        oracle.commit(requestId, c1);
        vm.prank(agent2);
        oracle.commit(requestId, c2);

        vm.prank(agent1);
        oracle.reveal(requestId, a1, 1);
        vm.prank(agent2);
        oracle.reveal(requestId, a2, 2);

        address judge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;

        vm.prank(judge);
        oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("correct"));

        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        vm.expectRevert(NousOracle.ETHSentWithERC20Bond.selector);
        oracle.initiateDispute{value: 0.15 ether}(requestId, "Wrong token");
    }

    // ============ Dispute: resolveDispute Tests ============

    function test_resolveDispute_upheld() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        uint256 agent1BalBefore = agent1.balance;
        uint256 requesterBalBefore = requester.balance;
        uint256 disputeBondAmount = oracle.disputeBondPaid(requestId);

        vm.prank(dJudge);
        oracle.resolveDispute(requestId, false, "", new address[](0));

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        uint256 winnersShare = disputeBondAmount / 2;
        uint256 requesterShare = disputeBondAmount / 2;
        assertEq(agent1.balance, agent1BalBefore + winnersShare);
        assertEq(requester.balance, requesterBalBefore + requesterShare);
    }

    function test_resolveDispute_overturned() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        address disputerAddr = oracle.disputer(requestId);
        uint256 disputerBalBefore = disputerAddr.balance;
        uint256 disputeBondAmount = oracle.disputeBondPaid(requestId);

        address[] memory newWinners = new address[](1);
        newWinners[0] = agent2;

        vm.prank(dJudge);
        oracle.resolveDispute(requestId, true, abi.encode("cloudy, revised"), newWinners);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        assertEq(disputerAddr.balance, disputerBalBefore + disputeBondAmount);

        address[] memory currentWinners = oracle.getWinners(requestId);
        assertEq(currentWinners.length, 1);
        assertEq(currentWinners[0], agent2);

        (bytes memory finalAnswer,) = oracle.getResolution(requestId);
        assertEq(finalAnswer, abi.encode("cloudy, revised"));
    }

    function test_resolveDispute_revertsIfNotDisputeJudge() public {
        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        vm.prank(agent1);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.NotDisputeJudge.selector, requestId, agent1));
        oracle.resolveDispute(requestId, false, "", new address[](0));
    }

    // ============ Dispute: DAO Escalation Tests ============

    function test_initiateDAOEscalation() public {
        address dao = makeAddr("dao");
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        oracle.setDaoResolutionWindow(7 days);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        vm.prank(dJudge);
        oracle.resolveDispute(requestId, false, "", new address[](0));

        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);

        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DAOEscalation));
        assertTrue(oracle.daoEscalationUsed(requestId));
        assertEq(oracle.daoEscalator(requestId), escalator);
        assertEq(oracle.daoEscalationBondPaid(requestId), 1 ether);
        assertGt(oracle.daoEscalationDeadline(requestId), block.timestamp);
    }

    function test_initiateDAOEscalation_revertsBeforeDispute() public {
        address dao = makeAddr("dao");
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
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

        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);

        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        vm.expectRevert();
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();
    }

    function test_resolveDAOEscalation_upheld() public {
        uint256 requestId = _createDefaultRequest(2);
        (address dao, MockERC20 taikoToken) = _driveToDAOEscalation(requestId);

        address[] memory currentWinners = oracle.getWinners(requestId);
        uint256 escalationBond = oracle.daoEscalationBondPaid(requestId);

        uint256 winnersTokenBefore = taikoToken.balanceOf(currentWinners[0]);
        uint256 requesterTokenBefore = taikoToken.balanceOf(requester);

        vm.prank(dao);
        oracle.resolveDAOEscalation(requestId, false, "", new address[](0));

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
        assertLe(oracle.disputeWindowEnd(requestId), block.timestamp);

        uint256 winnersShare = escalationBond / 2;
        uint256 requesterShareExpected = escalationBond / 2;
        assertEq(taikoToken.balanceOf(currentWinners[0]), winnersTokenBefore + winnersShare);
        assertEq(taikoToken.balanceOf(requester), requesterTokenBefore + requesterShareExpected);
    }

    function test_resolveDAOEscalation_overturned() public {
        uint256 requestId = _createDefaultRequest(2);
        (address dao, MockERC20 taikoToken) = _driveToDAOEscalation(requestId);

        address escalator = oracle.daoEscalator(requestId);
        uint256 escalatorTokenBefore = taikoToken.balanceOf(escalator);
        uint256 escalationBond = oracle.daoEscalationBondPaid(requestId);

        address[] memory newWinners = new address[](1);
        newWinners[0] = agent2;

        vm.prank(dao);
        oracle.resolveDAOEscalation(requestId, true, abi.encode("cloudy, DAO decision"), newWinners);

        assertEq(taikoToken.balanceOf(escalator), escalatorTokenBefore + escalationBond);

        address[] memory updated = oracle.getWinners(requestId);
        assertEq(updated[0], agent2);

        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    }

    function test_timeoutDAOEscalation() public {
        uint256 requestId = _createDefaultRequest(2);
        (address dao, MockERC20 taikoToken) = _driveToDAOEscalation(requestId);

        address escalator = oracle.daoEscalator(requestId);
        uint256 escalatorTokenBefore = taikoToken.balanceOf(escalator);
        uint256 escalationBond = oracle.daoEscalationBondPaid(requestId);

        vm.warp(block.timestamp + 7 days + 1);

        oracle.timeoutDAOEscalation(requestId);

        assertEq(taikoToken.balanceOf(escalator), escalatorTokenBefore + escalationBond);

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
        assertLe(oracle.disputeWindowEnd(requestId), block.timestamp);

        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    }

    // ============ Full Dispute E2E Test ============

    function test_fullDisputeFlow_E2E() public {
        address dao = makeAddr("dao");
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        oracle.setDaoResolutionWindow(7 days);
        vm.stopPrank();

        // 1. Create request
        uint256 requestId = _createDefaultRequest(2);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Committing));

        // 2. Agents commit
        bytes memory answer1 = abi.encode("sunny, 22C");
        bytes memory answer2 = abi.encode("cloudy, 20C");
        _commitAgent(requestId, agent1, answer1, 42);
        _commitAgent(requestId, agent2, answer2, 99);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Revealing));

        // 3. Agents reveal
        _revealAgent(requestId, agent1, answer1, 42);
        _revealAgent(requestId, agent2, answer2, 99);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Judging));

        // 4. Judge aggregates
        address originalJudge = oracle.selectedJudge(requestId);
        address[] memory winners = new address[](1);
        winners[0] = agent1;
        vm.prank(originalJudge);
        oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("agent1 correct"));
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        // 5. Dispute filed
        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);
        vm.prank(disputerAddr);
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "I disagree");
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Disputed));

        // 6. Dispute judge overturns
        address dJudge = oracle.disputeJudge(requestId);
        assertTrue(dJudge != originalJudge);
        address[] memory newWinners = new address[](1);
        newWinners[0] = agent2;
        vm.prank(dJudge);
        oracle.resolveDispute(requestId, true, abi.encode("cloudy"), newWinners);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        // 7. DAO escalation
        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);
        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DAOEscalation));

        // 8. DAO overturns back to both agents
        address[] memory daoWinners = new address[](2);
        daoWinners[0] = agent1;
        daoWinners[1] = agent2;
        vm.prank(dao);
        oracle.resolveDAOEscalation(requestId, true, abi.encode("both correct"), daoWinners);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

        // 9. Distribute (window immediately expired after DAO)
        uint256 agent1Bal = agent1.balance;
        uint256 agent2Bal = agent2.balance;
        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));

        assertGt(agent1.balance, agent1Bal);
        assertGt(agent2.balance, agent2Bal);

        (, bool finalized) = oracle.getResolution(requestId);
        assertTrue(finalized);
    }

    // ============ Dispute: Setter & Edge Case Tests ============

    function test_setDisputeBondMultiplier_revertsIfTooLow() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeBondMultiplierTooLow.selector, 99));
        oracle.setDisputeBondMultiplier(99);
    }

    function test_setDaoEscalationBondToken_revertsIfZero() public {
        vm.prank(owner);
        vm.expectRevert(NousOracle.InvalidBondTokenAddress.selector);
        oracle.setDaoEscalationBondToken(address(0));
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(agent1);

        vm.expectRevert();
        oracle.setDisputeWindow(1 hours);

        vm.expectRevert();
        oracle.setDisputeBondMultiplier(200);

        vm.expectRevert();
        oracle.setDaoEscalationBond(1 ether);

        vm.expectRevert();
        oracle.setDaoAddress(agent1);

        vm.stopPrank();
    }

    function test_disputeWindowExpiry_exactTimestamp() public {
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

        uint256 windowEnd = oracle.disputeWindowEnd(requestId);
        vm.warp(windowEnd);

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeWindowNotOpen.selector, requestId));
        oracle.initiateDispute{value: disputeBondRequired}(requestId, "Exact deadline");
    }

    function test_disputeWindow_noDisputeDistribute() public {
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

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 agent1Bal = agent1.balance;
        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
        assertGt(agent1.balance, agent1Bal);
    }

    function test_initiateDispute_revertsInsufficientBond() public {
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

        uint256 disputeBondRequired = BOND * 150 / 100;
        address disputerAddr = makeAddr("disputer");
        vm.deal(disputerAddr, 1 ether);

        vm.prank(disputerAddr);
        vm.expectRevert(abi.encodeWithSelector(NousOracle.InsufficientDisputeBond.selector, disputeBondRequired, 0.01 ether));
        oracle.initiateDispute{value: 0.01 ether}(requestId, "Underfunded");
    }

    function test_initiateDAOEscalation_revertsIfDAONotSet() public {
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        vm.prank(dJudge);
        oracle.resolveDispute(requestId, false, "", new address[](0));

        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);

        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        vm.expectRevert(NousOracle.DAONotSet.selector);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();
    }

    function test_initiateDAOEscalation_revertsIfAlreadyUsed() public {
        address dao = makeAddr("dao");
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        oracle.setDaoResolutionWindow(7 days);
        vm.stopPrank();

        uint256 requestId = _createDefaultRequest(2);
        _driveToDisputed(requestId);

        address dJudge = oracle.disputeJudge(requestId);
        vm.prank(dJudge);
        oracle.resolveDispute(requestId, false, "", new address[](0));

        address escalator1 = makeAddr("escalator1");
        taikoToken.mint(escalator1, 10 ether);
        vm.startPrank(escalator1);
        taikoToken.approve(address(oracle), 1 ether);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();

        vm.prank(dao);
        oracle.resolveDAOEscalation(requestId, false, "", new address[](0));

        address escalator2 = makeAddr("escalator2");
        taikoToken.mint(escalator2, 10 ether);
        vm.startPrank(escalator2);
        taikoToken.approve(address(oracle), 1 ether);
        vm.expectRevert();
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();
    }

    // ============ Single Judge: Direct DAO Escalation ============

    function test_initiateDAOEscalation_directWithSingleJudge() public {
        // Remove judge2 so only judge1 remains
        address dao = makeAddr("dao");
        MockERC20 taikoToken = new MockERC20();

        vm.startPrank(owner);
        oracle.removeJudge(judge2);
        oracle.setDisputeWindow(1 hours);
        oracle.setDisputeBondMultiplier(150);
        oracle.setDaoAddress(dao);
        oracle.setDaoEscalationBondToken(address(taikoToken));
        oracle.setDaoEscalationBond(1 ether);
        oracle.setDaoResolutionWindow(7 days);
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

        // In DisputeWindow, disputeUsed is false, but only 1 judge — can go to DAO directly
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
        assertFalse(oracle.disputeUsed(requestId));

        address escalator = makeAddr("escalator");
        taikoToken.mint(escalator, 10 ether);

        vm.startPrank(escalator);
        taikoToken.approve(address(oracle), 1 ether);
        oracle.initiateDAOEscalation(requestId);
        vm.stopPrank();

        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DAOEscalation));

        // DAO resolves
        address[] memory newWinners = new address[](1);
        newWinners[0] = agent2;
        vm.prank(dao);
        oracle.resolveDAOEscalation(requestId, true, abi.encode("cloudy"), newWinners);

        // Can distribute
        oracle.distributeRewards(requestId);
        assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    }

    // ============ Staking Registration Tests ============

    function test_registerAgent_info() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        (uint256 amount, NousOracle.AgentRole role, bool registered, uint256 withdrawTime) = oracle.agentStakes(agent1);
        assertEq(amount, MIN_STAKE);
        assertEq(uint8(role), uint8(NousOracle.AgentRole.Info));
        assertTrue(registered);
        assertEq(withdrawTime, 0);

        address[] memory infoAgents = oracle.getRegisteredInfoAgents();
        assertEq(infoAgents.length, 1);
        assertEq(infoAgents[0], agent1);
    }

    function test_registerAgent_judge() public {
        _setupStaking();

        vm.deal(judge1, 10 ether);
        vm.prank(judge1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Judge);

        (uint256 amount, NousOracle.AgentRole role, bool registered,) = oracle.agentStakes(judge1);
        assertEq(amount, MIN_STAKE);
        assertEq(uint8(role), uint8(NousOracle.AgentRole.Judge));
        assertTrue(registered);

        address[] memory judges = oracle.getRegisteredJudges();
        assertEq(judges.length, 1);
        assertEq(judges[0], judge1);
    }

    function test_registerAgent_revertsIfAlreadyRegistered() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.expectRevert(abi.encodeWithSelector(NousOracle.AlreadyRegistered.selector, agent1));
        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);
    }

    function test_registerAgent_revertsIfBelowMinStake() public {
        _setupStaking();

        vm.expectRevert(abi.encodeWithSelector(NousOracle.InsufficientStake.selector, MIN_STAKE, 0.1 ether));
        vm.prank(agent1);
        oracle.registerAgent{value: 0.1 ether}(NousOracle.AgentRole.Info);
    }

    function test_setMinStakeAmount() public {
        vm.prank(owner);
        oracle.setMinStakeAmount(1 ether);
        assertEq(oracle.minStakeAmount(), 1 ether);
    }

    function test_setSlashPercentage() public {
        vm.prank(owner);
        oracle.setSlashPercentage(3000);
        assertEq(oracle.slashPercentage(), 3000);
    }

    function test_setSlashPercentage_revertsIfTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(NousOracle.SlashPercentageTooHigh.selector, 10001));
        vm.prank(owner);
        oracle.setSlashPercentage(10001);
    }

    function test_setWithdrawalCooldown() public {
        vm.prank(owner);
        oracle.setWithdrawalCooldown(2 days);
        assertEq(oracle.withdrawalCooldown(), 2 days);
    }

    // ============ Stake Top-Up Tests ============

    function test_addStake() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.prank(agent1);
        oracle.addStake{value: 0.5 ether}(0);

        (uint256 amount,,,) = oracle.agentStakes(agent1);
        assertEq(amount, 1 ether);
    }

    function test_addStake_revertsIfNotRegistered() public {
        _setupStaking();

        vm.expectRevert(abi.encodeWithSelector(NousOracle.NotRegistered.selector, agent1));
        vm.prank(agent1);
        oracle.addStake{value: 0.5 ether}(0);
    }

    // ============ Withdrawal Tests ============

    function test_requestWithdrawal() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.prank(agent1);
        oracle.requestWithdrawal();

        (,, bool registered, uint256 withdrawTime) = oracle.agentStakes(agent1);
        assertFalse(registered);
        assertGt(withdrawTime, 0);

        address[] memory infoAgents = oracle.getRegisteredInfoAgents();
        assertEq(infoAgents.length, 0);
    }

    function test_executeWithdrawal() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.prank(agent1);
        oracle.requestWithdrawal();

        vm.warp(block.timestamp + WITHDRAW_COOLDOWN + 1);

        uint256 balanceBefore = agent1.balance;
        vm.prank(agent1);
        oracle.executeWithdrawal();

        assertEq(agent1.balance, balanceBefore + MIN_STAKE);

        (uint256 amount,,, uint256 withdrawTime) = oracle.agentStakes(agent1);
        assertEq(amount, 0);
        assertEq(withdrawTime, 0);
    }

    function test_executeWithdrawal_revertsIfCooldownNotElapsed() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.prank(agent1);
        oracle.requestWithdrawal();

        vm.expectRevert();
        vm.prank(agent1);
        oracle.executeWithdrawal();
    }

    function test_cancelWithdrawal() public {
        _setupStaking();

        vm.prank(agent1);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

        vm.prank(agent1);
        oracle.requestWithdrawal();

        vm.prank(agent1);
        oracle.cancelWithdrawal();

        (,, bool registered, uint256 withdrawTime) = oracle.agentStakes(agent1);
        assertTrue(registered);
        assertEq(withdrawTime, 0);

        address[] memory infoAgents = oracle.getRegisteredInfoAgents();
        assertEq(infoAgents.length, 1);
    }

    // ============ Staking Helpers ============

    function _registerInfoAgent(address agent) internal {
        vm.deal(agent, 10 ether);
        vm.prank(agent);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);
    }

    function _registerJudgeAgent(address judge) internal {
        vm.deal(judge, 10 ether);
        vm.prank(judge);
        oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Judge);
    }

    function _createStakedRequest() internal returns (uint256) {
        return _createStakedRequest(2);
    }

    function _createStakedRequest(uint256 numAgents) internal returns (uint256) {
        vm.prank(requester);
        return oracle.createRequest{value: REWARD}(
            "What is the weather in Tokyo?",
            numAgents,
            REWARD,
            0, // bondAmount = 0 for staking model
            block.timestamp + 1 hours,
            address(0),
            address(0),
            "Return JSON with temperature and conditions",
            _defaultCapabilities()
        );
    }

    // ============ Staking: Agent Selection Tests ============

    function test_createRequest_selectsAgents() public {
        _setupStaking();
        _registerInfoAgent(agent1);
        _registerInfoAgent(agent2);
        _registerInfoAgent(agent3);
        _registerJudgeAgent(judge1);

        uint256 requestId = _createStakedRequest(2);

        address[] memory selected = oracle.getSelectedAgents(requestId);
        assertEq(selected.length, 2);

        // Each selected agent should have activeAssignments incremented
        uint256 totalAssignments;
        for (uint256 i; i < selected.length; i++) {
            assertEq(oracle.activeAssignments(selected[i]), 1);
            totalAssignments++;
        }
        assertEq(totalAssignments, 2);
    }

    function test_createRequest_revertsIfInsufficientRegisteredAgents() public {
        _setupStaking();
        _registerInfoAgent(agent1);
        _registerJudgeAgent(judge1);

        vm.expectRevert(abi.encodeWithSelector(NousOracle.InsufficientRegisteredAgents.selector, 2, 1));
        _createStakedRequest(2);
    }

    function test_createRequest_revertsIfNoRegisteredJudges() public {
        _setupStaking();
        _registerInfoAgent(agent1);
        _registerInfoAgent(agent2);

        vm.expectRevert(NousOracle.NoJudgesAvailable.selector);
        _createStakedRequest(2);
    }

    function test_requestWithdrawal_revertsIfActiveAssignments() public {
        _setupStaking();
        _registerInfoAgent(agent1);
        _registerInfoAgent(agent2);
        _registerJudgeAgent(judge1);

        _createStakedRequest(2);

        // Find which agent was selected
        // Both agents registered so at least one will be selected
        // Try agent1 first - if not selected, agent2 must be
        bool agent1Selected = oracle.activeAssignments(agent1) > 0;
        address selectedAgent = agent1Selected ? agent1 : agent2;

        vm.expectRevert(abi.encodeWithSelector(NousOracle.ActiveAssignmentsPending.selector, selectedAgent, 1));
        vm.prank(selectedAgent);
        oracle.requestWithdrawal();
    }
}
