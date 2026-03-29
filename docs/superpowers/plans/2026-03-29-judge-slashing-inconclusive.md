# Judge Slashing & Inconclusive Outcomes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add judge slashing on overturned decisions and allow judges/DAO to declare "inconclusive" outcomes that refund everything.

**Architecture:** Add new storage for tracking slash targets and per-request slash history. Add `_slashAgentForRequest()` wrapper. Modify `aggregate()` to allow empty winners. Modify `resolveDispute()` and `resolveDAOEscalation()` to set slash targets. Modify `distributeRewards()` to execute judge slash and handle inconclusive refunds. Change `resolveDAOEscalation` signature from `bool overturn` to `uint8 outcome`.

**Tech Stack:** Solidity 0.8.28, Foundry (forge)

**Spec:** `docs/superpowers/specs/2026-03-29-judge-slashing-inconclusive-design.md`

---

### Task 1: Add New Storage, Events, Errors, and `_slashAgentForRequest`

**Files:**
- Modify: `src/NousOracle.sol`
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Add new storage variables**

In `src/NousOracle.sol`, after `disputeBondAmount` (line 176), add:

```solidity
/// @notice Judge to slash at distribution time.
mapping(uint256 => address) public judgeToSlash;

/// @notice Beneficiary of 50% of slashed judge stake.
mapping(uint256 => address) public slashBeneficiary;

/// @notice Agents slashed during this request (for restore on inconclusive).
mapping(uint256 => address[]) internal _slashedAgents;

/// @notice Amount slashed per agent per request.
mapping(uint256 => mapping(address => uint256)) internal _slashedAmounts;
```

- [ ] **Step 2: Add new event and error**

After existing staking events (after line 227), add:

```solidity
event JudgeSlashed(uint256 indexed requestId, address judge, uint256 amount, address beneficiary);
event InconclusiveResolution(uint256 indexed requestId);
event StakeRestored(address indexed agent, uint256 amount);
```

After existing staking errors (after line 261), add:

```solidity
error InvalidDAOOutcome(uint8 outcome);
```

- [ ] **Step 3: Add `_slashAgentForRequest` wrapper**

After the existing `_slashAgent` function (after line 1341), add:

```solidity
/// @dev Slash an agent and record it per-request for potential restore.
function _slashAgentForRequest(uint256 requestId, address agent) internal returns (uint256 slashed) {
    slashed = _slashAgent(agent);
    if (slashed > 0) {
        _slashedAgents[requestId].push(agent);
        _slashedAmounts[requestId][agent] += slashed;
    }
}
```

- [ ] **Step 4: Replace all `_slashAgent` calls with `_slashAgentForRequest`**

In `endCommitPhase()` (around lines 654-683), replace every `_slashAgent(...)` with `_slashAgentForRequest(requestId, ...)`. There are 2 call sites:

1. Line ~657: `_slashAgent(selected[i])` → `_slashAgentForRequest(requestId, selected[i])`
2. Line ~680: `uint256 slashed = _slashAgent(selected[i])` → `uint256 slashed = _slashAgentForRequest(requestId, selected[i])`

In `endRevealPhase()` (around lines 736-773), replace:

1. Line ~741: `_slashAgent(agent)` → `_slashAgentForRequest(requestId, agent)`
2. Line ~769: `uint256 slashed = _slashAgent(agent)` → `uint256 slashed = _slashAgentForRequest(requestId, agent)`

In `aggregate()` (around lines 804-821), replace:

1. Line ~817: `uint256 slashed = _slashAgent(agent)` → `uint256 slashed = _slashAgentForRequest(requestId, agent)`

- [ ] **Step 5: Write test to verify `_slashAgentForRequest` records slashes**

Add to `test/NousOracle.t.sol`:

```solidity
// ============ Judge Slashing: Slash Tracking Tests ============

function test_slashAgentForRequest_tracksSlashes() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    // Only selected[0] commits, selected[1] doesn't
    bytes32 commitment = keccak256(abi.encode(abi.encode("answer"), uint256(1)));
    vm.prank(selected[0]);
    oracle.commit(requestId, commitment);

    vm.warp(block.timestamp + 1 hours + 1);
    oracle.endCommitPhase(requestId);

    // Verify slash was tracked — we can check via the slashed stake amount
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    assertEq(oracle.requestSlashedStake(requestId), expectedSlash);
}
```

- [ ] **Step 6: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: add judge slash storage and _slashAgentForRequest wrapper"
```

---

### Task 2: Allow Inconclusive Judgments in `aggregate()`

**Files:**
- Modify: `src/NousOracle.sol` (aggregate function, lines 780-828)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for inconclusive judgment**

```solidity
function test_aggregate_inconclusive() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    // Judge declares inconclusive — empty winners
    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory noWinners = new address[](0);
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("inconclusive"), noWinners, abi.encode("can't determine"));

    // Should be in DisputeWindow (can still be disputed)
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

    // No losers slashed (no winners means no losers)
    assertEq(oracle.requestSlashedStake(requestId), 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_aggregate_inconclusive -vvv`
Expected: FAIL with `NoWinners()` revert.

- [ ] **Step 3: Modify `aggregate()` to allow empty winners**

In `aggregate()`, remove line 791: `if (winners.length == 0) revert NoWinners();`

Then wrap the winner validation and loser slashing in a condition:

```solidity
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
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: allow inconclusive judgments with empty winners"
```

---

### Task 3: Add Judge Slash Tracking in `resolveDispute()`

**Files:**
- Modify: `src/NousOracle.sol` (resolveDispute, lines 969-1003)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test**

```solidity
function test_resolveDispute_overturned_setsJudgeToSlash() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDisputeBondAmount(0.2 ether);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address originalJudge = oracle.selectedJudge(requestId);
    address[] memory winners1 = new address[](1);
    winners1[0] = selected[0];
    vm.prank(originalJudge);
    oracle.aggregate(requestId, abi.encode("sunny"), winners1, abi.encode("reason"));

    // File dispute
    address disputerAddr = makeAddr("disputerSlash");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Wrong answer");
    vm.stopPrank();

    // Dispute judge overturns
    address dJudge = oracle.disputeJudge(requestId);
    address[] memory winners2 = new address[](1);
    winners2[0] = selected[1];
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, true, abi.encode("cloudy"), winners2);

    // judgeToSlash should be the original judge
    assertEq(oracle.judgeToSlash(requestId), originalJudge);
    assertEq(oracle.slashBeneficiary(requestId), disputerAddr);
}

function test_resolveDispute_upheld_clearsJudgeToSlash() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDisputeBondAmount(0.2 ether);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address originalJudge = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];
    vm.prank(originalJudge);
    oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("reason"));

    address disputerAddr = makeAddr("disputerUpheld");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Wrong");
    vm.stopPrank();

    // Dispute judge upholds
    address dJudge = oracle.disputeJudge(requestId);
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, false, "", new address[](0));

    // No judge to slash
    assertEq(oracle.judgeToSlash(requestId), address(0));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_resolveDispute.*slash\|test_resolveDispute.*Slash" -vvv`
Expected: FAIL — `judgeToSlash` not set.

- [ ] **Step 3: Add slash tracking to `resolveDispute()`**

In `resolveDispute()`, after the `if (overturn)` block sets winners (around line 993), add:

```solidity
// Track judge to slash at distribution time
judgeToSlash[requestId] = selectedJudge[requestId];
slashBeneficiary[requestId] = disputer[requestId];
```

In the `else` (upheld) block (around line 994-996), add:

```solidity
// Judge was right — clear any slash target
judgeToSlash[requestId] = address(0);
slashBeneficiary[requestId] = address(0);
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: track judge to slash in resolveDispute"
```

---

### Task 4: Change `resolveDAOEscalation` to `uint8 outcome` with Inconclusive

**Files:**
- Modify: `src/NousOracle.sol` (resolveDAOEscalation, lines 1036-1069)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for DAO inconclusive**

```solidity
function test_resolveDAOEscalation_inconclusive() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    address dao = makeAddr("dao");
    MockERC20 taikoToken = token; // reuse existing mock

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDisputeBondAmount(0.2 ether);
    oracle.setDaoAddress(dao);
    oracle.setDaoEscalationBondToken(address(taikoToken));
    oracle.setDaoEscalationBond(1 ether);
    oracle.setDaoResolutionWindow(7 days);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("reason"));

    // File dispute
    address disputerAddr = makeAddr("disputerDAO");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Disagree");
    vm.stopPrank();

    // Dispute judge upholds
    address dJudge = oracle.disputeJudge(requestId);
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, false, "", new address[](0));

    // DAO escalation
    address escalator = makeAddr("escalator");
    taikoToken.mint(escalator, 10 ether);
    vm.startPrank(escalator);
    taikoToken.approve(address(oracle), 1 ether);
    oracle.initiateDAOEscalation(requestId);
    vm.stopPrank();

    // DAO declares inconclusive (outcome = 2)
    vm.prank(dao);
    oracle.resolveDAOEscalation(requestId, 2, "", new address[](0));

    // Winners should be cleared (empty)
    address[] memory finalWinners = oracle.getWinners(requestId);
    assertEq(finalWinners.length, 0);

    // Should be in DisputeWindow with immediate expiry
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_resolveDAOEscalation_inconclusive -vvv`
Expected: FAIL — signature mismatch (currently `bool overturn`).

- [ ] **Step 3: Change `resolveDAOEscalation` signature and logic**

Replace the entire `resolveDAOEscalation` function:

```solidity
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
```

- [ ] **Step 4: Also add judge slash tracking for DAO overturn in tests**

```solidity
function test_resolveDAOEscalation_overturned_slashesDisputeJudge() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    address dao = makeAddr("dao");

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDisputeBondAmount(0.2 ether);
    oracle.setDaoAddress(dao);
    oracle.setDaoEscalationBondToken(address(token));
    oracle.setDaoEscalationBond(1 ether);
    oracle.setDaoResolutionWindow(7 days);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address originalJudge = oracle.selectedJudge(requestId);
    address[] memory winners1 = new address[](1);
    winners1[0] = selected[0];
    vm.prank(originalJudge);
    oracle.aggregate(requestId, abi.encode("sunny"), winners1, abi.encode("reason"));

    // Dispute overturns
    address disputerAddr = makeAddr("disputerDAO2");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Wrong");
    vm.stopPrank();

    address dJudge = oracle.disputeJudge(requestId);
    address[] memory winners2 = new address[](1);
    winners2[0] = selected[1];
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, true, abi.encode("cloudy"), winners2);

    // DAO escalation overturns dispute judge's decision
    address escalator = makeAddr("escalator2");
    token.mint(escalator, 10 ether);
    vm.startPrank(escalator);
    token.approve(address(oracle), 1 ether);
    oracle.initiateDAOEscalation(requestId);
    vm.stopPrank();

    address[] memory winners3 = new address[](1);
    winners3[0] = selected[0];
    vm.prank(dao);
    oracle.resolveDAOEscalation(requestId, 1, abi.encode("sunny after all"), winners3);

    // Dispute judge should be slashed (not original judge)
    assertEq(oracle.judgeToSlash(requestId), dJudge);
    assertEq(oracle.slashBeneficiary(requestId), escalator);
}
```

- [ ] **Step 5: Update existing DAO tests that use `bool overturn`**

Find all existing tests calling `resolveDAOEscalation` with `true`/`false` and change to `1`/`0`:
- `test_resolveDAOEscalation_upheld`: change `false` → `0`
- `test_resolveDAOEscalation_overturned`: change `true` → `1`
- Any test in `_driveToDAOEscalation` helpers or E2E tests

Search for `oracle.resolveDAOEscalation(requestId, true` and replace `true` with `1`.
Search for `oracle.resolveDAOEscalation(requestId, false` and replace `false` with `0`.

- [ ] **Step 6: Update `IAgentCouncilOracle.sol` if it declares `resolveDAOEscalation`**

Check if the interface declares this function. If so, update signature. If not (likely — dispute functions aren't in the ERC-8033 interface), skip.

- [ ] **Step 7: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 8: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: DAO resolveEscalation with 3 outcomes, judge slash tracking"
```

---

### Task 5: Execute Judge Slash and Handle Inconclusive in `distributeRewards()`

**Files:**
- Modify: `src/NousOracle.sol` (distributeRewards, lines 831-911)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for judge slash at distribution**

```solidity
function test_distributeRewards_slashesJudge() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondAmount(0.2 ether);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address originalJudge = oracle.selectedJudge(requestId);
    (uint256 judgeBefore,,,) = oracle.agentStakes(originalJudge);

    address[] memory winners1 = new address[](1);
    winners1[0] = selected[0];
    vm.prank(originalJudge);
    oracle.aggregate(requestId, abi.encode("sunny"), winners1, abi.encode("reason"));

    // Dispute overturns
    address disputerAddr = makeAddr("disputerSlashDist");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Wrong");
    vm.stopPrank();

    address dJudge = oracle.disputeJudge(requestId);
    address[] memory winners2 = new address[](1);
    winners2[0] = selected[1];
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, true, abi.encode("cloudy"), winners2);

    // Dispute window expires
    vm.warp(block.timestamp + 1 hours + 1);

    uint256 disputerBalBefore = token.balanceOf(disputerAddr);
    oracle.distributeRewards(requestId);

    // Judge was slashed
    (uint256 judgeAfter,,,) = oracle.agentStakes(originalJudge);
    uint256 expectedSlash = judgeBefore * SLASH_PCT / 10000;
    assertEq(judgeAfter, judgeBefore - expectedSlash);

    // Disputer got 50% of judge's slashed stake
    uint256 beneficiaryShare = expectedSlash / 2;
    assertGe(token.balanceOf(disputerAddr), disputerBalBefore + beneficiaryShare);
}
```

- [ ] **Step 2: Write failing test for inconclusive distribution**

```solidity
function test_distributeRewards_inconclusive_refundsEverything() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");

    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    // Judge declares inconclusive
    address judgeAddr = oracle.selectedJudge(requestId);
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("inconclusive"), new address[](0), abi.encode("unclear"));

    vm.warp(block.timestamp + 1 hours + 1);

    // Record balances before
    uint256 requesterBalBefore = token.balanceOf(requester);
    (uint256 agent0StakeBefore,,,) = oracle.agentStakes(selected[0]);
    (uint256 agent1StakeBefore,,,) = oracle.agentStakes(selected[1]);

    oracle.distributeRewards(requestId);

    // Requester gets reward back
    assertEq(token.balanceOf(requester), requesterBalBefore + REWARD);

    // Phase is Failed
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Failed));

    // Active assignments decremented
    assertEq(oracle.activeAssignments(selected[0]), 0);
    assertEq(oracle.activeAssignments(selected[1]), 0);
}
```

- [ ] **Step 3: Modify `distributeRewards()` staking path**

In the staking model block of `distributeRewards()` (after line 847 `bool isStakingModel = ...`), restructure:

```solidity
if (isStakingModel) {
    // Execute deferred judge slash (if any)
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
            uint256 amount = _slashedAmounts[requestId][agent];
            if (amount > 0) {
                agentStakes[agent].amount += amount;
                // Re-register if eligible
                if (agentStakes[agent].amount >= minStakeAmount && !agentStakes[agent].registered && agentStakes[agent].withdrawRequestTime == 0) {
                    agentStakes[agent].registered = true;
                    if (agentStakes[agent].role == AgentRole.Info) {
                        _registeredInfoAgents.push(agent);
                    } else {
                        _registeredJudges.push(agent);
                    }
                }
                emit StakeRestored(agent, amount);
            }
        }

        // Return dispute bond if used
        if (disputeUsed[requestId] && disputeBondPaid[requestId] > 0) {
            _transferToken(stakeToken, disputer[requestId], disputeBondPaid[requestId]);
        }

        // Return DAO escalation bond if used
        if (daoEscalationUsed[requestId] && daoEscalationBondPaid[requestId] > 0) {
            IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], daoEscalationBondPaid[requestId]);
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
            _transferToken(req.rewardToken, winner, totalPayout);
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
    // Legacy bond model (unchanged)
    ...
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: judge slashing at distribution, inconclusive refund logic"
```

---

### Task 6: Full E2E Tests

**Files:**
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write E2E test for judge slash flow**

```solidity
function test_fullFlow_judgeSlashed() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondAmount(0.2 ether);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("answer1");
    bytes memory a2 = abi.encode("answer2");
    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address originalJudge = oracle.selectedJudge(requestId);
    (uint256 judgeBefore,,,) = oracle.agentStakes(originalJudge);

    address[] memory winners1 = new address[](1);
    winners1[0] = selected[0];
    vm.prank(originalJudge);
    oracle.aggregate(requestId, a1, winners1, abi.encode("reason"));

    address disputerAddr = makeAddr("e2eDisputer");
    token.mint(disputerAddr, 10 ether);
    vm.startPrank(disputerAddr);
    token.approve(address(oracle), type(uint256).max);
    oracle.initiateDispute(requestId, "Wrong pick");
    vm.stopPrank();

    address dJudge = oracle.disputeJudge(requestId);
    address[] memory winners2 = new address[](1);
    winners2[0] = selected[1];
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, true, a2, winners2);

    vm.warp(block.timestamp + 1 hours + 1);
    oracle.distributeRewards(requestId);

    // Verify judge was slashed
    (uint256 judgeAfter,,,) = oracle.agentStakes(originalJudge);
    assertLt(judgeAfter, judgeBefore);

    // Verify phase
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
}

function test_fullFlow_inconclusive() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    vm.stopPrank();

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    bytes memory a1 = abi.encode("answer1");
    bytes memory a2 = abi.encode("answer2");
    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(1))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(2))));
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 2);

    address judgeAddr = oracle.selectedJudge(requestId);
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("inconclusive"), new address[](0), abi.encode("unclear"));

    vm.warp(block.timestamp + 1 hours + 1);

    uint256 requesterBal = token.balanceOf(requester);
    oracle.distributeRewards(requestId);

    // Requester refunded
    assertEq(token.balanceOf(requester), requesterBal + REWARD);

    // Phase is Failed
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Failed));

    // Judge NOT slashed
    (uint256 judgeStake,,,) = oracle.agentStakes(judgeAddr);
    assertEq(judgeStake, MIN_STAKE);
}
```

- [ ] **Step 2: Run all tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add test/NousOracle.t.sol
git commit -m "test: add E2E tests for judge slashing and inconclusive flows"
```

---

### Task 7: Update Client ABI

**Files:**
- Modify: `client/src/oracleAbi.ts`

- [ ] **Step 1: Add new view functions to ABI**

Add to `oracleAbi` array:

```typescript
{
  type: 'function',
  name: 'judgeToSlash',
  stateMutability: 'view',
  inputs: [{ name: 'requestId', type: 'uint256' }],
  outputs: [{ name: '', type: 'address' }],
},
{
  type: 'function',
  name: 'slashBeneficiary',
  stateMutability: 'view',
  inputs: [{ name: 'requestId', type: 'uint256' }],
  outputs: [{ name: '', type: 'address' }],
},
```

- [ ] **Step 2: Update `resolveDAOEscalation` ABI entry if it exists**

Search for `resolveDAOEscalation` in the ABI. If it exists, change the `overturn` parameter from `bool` to `uint8` type named `outcome`. If it doesn't exist in the client ABI (likely — the client doesn't call DAO functions), skip.

- [ ] **Step 3: Verify TypeScript compiles**

Run: `cd /Users/davidcai/taiko/hackathon/nous/client && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add client/src/oracleAbi.ts
git commit -m "feat: add judge slash ABI entries to client"
```

---

### Task 8: Final Verification

- [ ] **Step 1: Run full Solidity test suite**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 2: Run TypeScript compilation**

Run: `cd /Users/davidcai/taiko/hackathon/nous/client && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Run forge build**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge build`
Expected: Successful compilation
