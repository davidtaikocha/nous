# Dispute Resolution & DAO Escalation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two-tier post-finalization challenge mechanism (dispute + DAO escalation) to NousOracle.sol per the design spec at `docs/superpowers/specs/2026-03-19-dispute-resolution-design.md`.

**Architecture:** Inline extension of `NousOracle.sol` — new phases appended to existing enum (UUPS-safe), new storage variables appended after existing ones, new functions in a clearly separated section. Modified `aggregate()` and `distributeRewards()` to route through dispute window. Client/UI updated for new phase names.

**Tech Stack:** Solidity 0.8.28, Foundry (forge), OpenZeppelin Upgradeable, TypeScript (viem)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/NousOracle.sol` | Modify | Add Phase enum values, storage, events, errors, dispute/DAO functions, modify aggregate/distributeRewards/getResolution |
| `test/NousOracle.t.sol` | Modify | Fix existing tests for new phase flow, add all dispute/DAO tests |
| `client/src/types.ts` | Modify | Add new phase names to `PhaseName` union |
| `client/src/chain.ts` | Modify | Add new phases to `PHASE_NAMES`, `ACTIVE_PHASES` |
| `web/index.html` | Modify | Update `PHASE_NAMES` array |

---

### Task 1: Extend Phase Enum & Add New Errors/Events

**Files:**
- Modify: `src/NousOracle.sol:19-27` (Phase enum)
- Modify: `src/NousOracle.sol:77-95` (errors section)

- [ ] **Step 1: Add three new Phase values after `Failed`**

In `src/NousOracle.sol`, change the Phase enum from:

```solidity
enum Phase {
    None,
    Committing,
    Revealing,
    Judging,
    Finalized,
    Distributed,
    Failed
}
```

to:

```solidity
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
```

- [ ] **Step 2: Add dispute/DAO events after existing events section**

Add after the `ResolutionFailed` event import (these are in the interface, but since NousOracle defines its own events inline, add them in `NousOracle.sol`):

```solidity
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
```

- [ ] **Step 3: Add dispute/DAO errors after existing errors**

```solidity
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
```

- [ ] **Step 4: Run `forge build` to verify compilation**

Run: `forge build`
Expected: Compiles successfully

- [ ] **Step 5: Commit**

```bash
git add src/NousOracle.sol
git commit -m "feat: extend Phase enum with DisputeWindow, Disputed, DAOEscalation"
```

---

### Task 2: Add Dispute Storage Variables & Setter Functions

**Files:**
- Modify: `src/NousOracle.sol` (storage section after `revealDeadlines`, add setters after judge management)

- [ ] **Step 1: Add new storage variables after `revealDeadlines`**

After line 75 (`mapping(uint256 => uint256) public revealDeadlines;`), add:

```solidity
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
```

- [ ] **Step 2: Add setter functions after judge management section**

After `getJudges()`, add:

```solidity
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
```

- [ ] **Step 3: Run `forge build` to verify compilation**

Run: `forge build`
Expected: Compiles successfully

- [ ] **Step 4: Commit**

```bash
git add src/NousOracle.sol
git commit -m "feat: add dispute storage variables and owner setter functions"
```

---

### Task 3: Modify `aggregate()`, `distributeRewards()`, and `getResolution()`

**Files:**
- Modify: `src/NousOracle.sol:308-392` (aggregate, distributeRewards, getResolution)

- [ ] **Step 1: Write failing test — aggregate transitions to DisputeWindow**

In `test/NousOracle.t.sol`, add at the end of the test contract (before the closing `}`):

```solidity
// ============ Dispute: Modified Existing Behavior ============

function test_aggregate_transitionsToDisputeWindow() public {
    // Setup dispute window on oracle
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

    // Should be DisputeWindow (7), not Finalized (4)
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
    assertGt(oracle.disputeWindowEnd(requestId), block.timestamp);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-test test_aggregate_transitionsToDisputeWindow -v`
Expected: FAIL — aggregate still produces Finalized

- [ ] **Step 3: Modify `aggregate()` to transition to DisputeWindow**

In `src/NousOracle.sol`, change `aggregate()`. Replace:

```solidity
phases[requestId] = Phase.Finalized;

emit ResolutionFinalized(requestId, finalAnswer);
```

with:

```solidity
phases[requestId] = Phase.DisputeWindow;
disputeWindowEnd[requestId] = block.timestamp + disputeWindow;

emit ResolutionFinalized(requestId, finalAnswer);
emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test --match-test test_aggregate_transitionsToDisputeWindow -v`
Expected: PASS

- [ ] **Step 5: Write failing test — distributeRewards requires expired dispute window**

```solidity
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

    // Try distributing before window expires — should revert
    vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeWindowNotExpired.selector, requestId));
    oracle.distributeRewards(requestId);

    // Warp past dispute window — should succeed
    vm.warp(block.timestamp + 1 hours + 1);
    oracle.distributeRewards(requestId);
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `forge test --match-test test_distributeRewards_requiresDisputeWindowExpired -v`
Expected: FAIL

- [ ] **Step 7: Modify `distributeRewards()` to accept DisputeWindow and Finalized**

Replace the entire `distributeRewards()` function:

```solidity
/// @inheritdoc IAgentCouncilOracle
function distributeRewards(uint256 requestId) external {
    Phase phase = phases[requestId];

    if (phase == Phase.DisputeWindow) {
        // New path: must wait for dispute window to expire
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
```

- [ ] **Step 8: Modify `getResolution()` — finalized only when Distributed**

Replace:

```solidity
finalized = phase == Phase.Finalized || phase == Phase.Distributed;
```

with:

```solidity
finalized = phase == Phase.Distributed;
```

- [ ] **Step 9: Run test to verify it passes**

Run: `forge test --match-test test_distributeRewards_requiresDisputeWindowExpired -v`
Expected: PASS

- [ ] **Step 10: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: aggregate transitions to DisputeWindow, distributeRewards checks window"
```

---

### Task 4: Fix Existing Tests for New Phase Flow

**Files:**
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Update `test_aggregate` — expect DisputeWindow phase**

Change:

```solidity
assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Finalized));
```

to:

```solidity
assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
```

And change:

```solidity
(bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
assertTrue(finalized);
```

to:

```solidity
(bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
assertFalse(finalized); // Not finalized until Distributed
```

- [ ] **Step 2: Update `test_distributeRewards_singleWinner` — add warp**

After the `oracle.aggregate(...)` call, before `oracle.distributeRewards(...)`, add:

```solidity
// Warp past dispute window
vm.warp(block.timestamp + oracle.disputeWindow() + 1);
```

- [ ] **Step 3: Update `test_distributeRewards_multipleWinners` — add warp**

Same pattern: add `vm.warp(block.timestamp + oracle.disputeWindow() + 1);` after aggregate, before distribute.

- [ ] **Step 4: Update `test_distributeRewards_erc20` — add warp**

Same pattern.

- [ ] **Step 5: Update `test_fullFlow` — expect DisputeWindow, add warp**

Change:

```solidity
assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Finalized));
```

to:

```solidity
assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
```

Change:

```solidity
(bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
assertTrue(finalized);
```

to:

```solidity
(bytes memory finalAnswer, bool finalized) = oracle.getResolution(requestId);
assertFalse(finalized); // Not finalized until distributed
```

Before `oracle.distributeRewards(requestId);`, add:

```solidity
// Warp past dispute window
vm.warp(block.timestamp + oracle.disputeWindow() + 1);
```

- [ ] **Step 6: Update `test_getWinnersAndReasoning` — expect DisputeWindow after aggregate**

This test calls aggregate but doesn't check phase directly. It should still work, but verify no assertions break.

- [ ] **Step 7: Run all tests**

Run: `forge test -v`
Expected: All tests PASS

- [ ] **Step 8: Commit**

```bash
git add test/NousOracle.t.sol
git commit -m "test: fix existing tests for dispute window phase flow"
```

---

### Task 5: Implement `initiateDispute()`

**Files:**
- Modify: `src/NousOracle.sol` (add function in new Dispute Functions section)
- Modify: `test/NousOracle.t.sol` (add tests)

- [ ] **Step 1: Write failing test — dispute happy path (ETH bond)**

```solidity
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

    // File dispute — bond is 0.1 ETH * 150 / 100 = 0.15 ETH
    uint256 disputeBondRequired = BOND * 150 / 100;
    address disputerAddr = makeAddr("disputer");
    vm.deal(disputerAddr, 1 ether);

    vm.prank(disputerAddr);
    oracle.initiateDispute{value: disputeBondRequired}(requestId, "Judge was wrong");

    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Disputed));
    assertTrue(oracle.disputeUsed(requestId));
    assertEq(oracle.disputer(requestId), disputerAddr);
    assertEq(oracle.disputeBondPaid(requestId), disputeBondRequired);

    // Dispute judge should be selected and NOT be the original judge
    address dJudge = oracle.disputeJudge(requestId);
    assertTrue(dJudge != address(0));
    assertTrue(dJudge != judge);
}
```

- [ ] **Step 2: Write failing test — dispute reverts if window expired**

```solidity
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

    // Warp past dispute window
    vm.warp(block.timestamp + 1 hours + 1);

    uint256 disputeBondRequired = BOND * 150 / 100;
    address disputerAddr = makeAddr("disputer");
    vm.deal(disputerAddr, 1 ether);

    vm.prank(disputerAddr);
    vm.expectRevert(abi.encodeWithSelector(NousOracle.DisputeWindowNotOpen.selector, requestId));
    oracle.initiateDispute{value: disputeBondRequired}(requestId, "Too late");
}
```

- [ ] **Step 3: Write failing test — dispute reverts if already used**

```solidity
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

    // Second dispute should fail (phase is now Disputed anyway, but test the guard)
    address disputer2 = makeAddr("disputer2");
    vm.deal(disputer2, 1 ether);
    vm.prank(disputer2);
    vm.expectRevert(); // Phase is Disputed, not DisputeWindow
    oracle.initiateDispute{value: disputeBondRequired}(requestId, "Second dispute");
}
```

- [ ] **Step 4: Write failing test — dispute reverts with only 1 judge**

```solidity
function test_initiateDispute_revertsIfNoOtherJudge() public {
    // Remove judge2 so only judge1 remains
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
```

- [ ] **Step 5: Write failing test — ETH sent with ERC-20 bond**

```solidity
function test_initiateDispute_revertsETHWithERC20Bond() public {
    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    vm.stopPrank();

    // Create ERC20-bond request
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

    // Try to send ETH with an ERC-20 bond request
    address disputerAddr = makeAddr("disputer");
    vm.deal(disputerAddr, 1 ether);

    vm.prank(disputerAddr);
    vm.expectRevert(NousOracle.ETHSentWithERC20Bond.selector);
    oracle.initiateDispute{value: 0.15 ether}(requestId, "Wrong token");
}
```

- [ ] **Step 6: Run tests to verify they all fail**

Run: `forge test --match-test "test_initiateDispute" -v`
Expected: All FAIL — `initiateDispute` doesn't exist yet

- [ ] **Step 7: Implement `initiateDispute()`**

Add in `src/NousOracle.sol` after the `distributeRewards()` function, in a new section:

```solidity
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
        // Refund excess
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

    // Select dispute judge (exclude original judge)
    _selectDisputeJudge(requestId);

    phases[requestId] = Phase.Disputed;

    emit DisputeInitiated(requestId, msg.sender, reason);
}
```

- [ ] **Step 8: Implement `_selectDisputeJudge()` helper**

Add in the Internal section:

```solidity
function _selectDisputeJudge(uint256 requestId) internal {
    address originalJudge = selectedJudge[requestId];
    uint256 judgeCount = _judgeList.length;

    // Build list of eligible judges (exclude original)
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
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `forge test --match-test "test_initiateDispute" -v`
Expected: All PASS

- [ ] **Step 10: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: implement initiateDispute with bond collection and judge selection"
```

---

### Task 6: Implement `resolveDispute()`

**Files:**
- Modify: `src/NousOracle.sol`
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test — dispute upheld (bond forfeited)**

Add a helper to drive requests to Disputed phase:

```solidity
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
```

Then the test:

```solidity
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

    // Uphold original decision
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, false, "", new address[](0));

    // Phase should be DisputeWindow again (second window for DAO escalation)
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

    // Disputer's bond forfeited: 50% to winners, 50% to requester
    uint256 winnersShare = disputeBondAmount / 2;
    uint256 requesterShare = disputeBondAmount / 2;
    assertEq(agent1.balance, agent1BalBefore + winnersShare);
    assertEq(requester.balance, requesterBalBefore + requesterShare);
}
```

- [ ] **Step 2: Write failing test — dispute overturned (new winners)**

```solidity
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

    // Overturn — agent2 is the new winner
    address[] memory newWinners = new address[](1);
    newWinners[0] = agent2;

    vm.prank(dJudge);
    oracle.resolveDispute(requestId, true, abi.encode("cloudy, revised"), newWinners);

    // Phase should be DisputeWindow
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));

    // Disputer's bond returned
    assertEq(disputerAddr.balance, disputerBalBefore + disputeBondAmount);

    // Winners updated
    address[] memory currentWinners = oracle.getWinners(requestId);
    assertEq(currentWinners.length, 1);
    assertEq(currentWinners[0], agent2);

    // Final answer updated
    (bytes memory finalAnswer,) = oracle.getResolution(requestId);
    assertEq(finalAnswer, abi.encode("cloudy, revised"));
}
```

- [ ] **Step 3: Write failing test — only dispute judge can resolve**

```solidity
function test_resolveDispute_revertsIfNotDisputeJudge() public {
    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    vm.stopPrank();

    uint256 requestId = _createDefaultRequest(2);
    _driveToDisputed(requestId);

    vm.prank(agent1); // not the dispute judge
    vm.expectRevert(abi.encodeWithSelector(NousOracle.NotDisputeJudge.selector, requestId, agent1));
    oracle.resolveDispute(requestId, false, "", new address[](0));
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `forge test --match-test "test_resolveDispute" -v`
Expected: All FAIL

- [ ] **Step 5: Implement `resolveDispute()`**

Add after `initiateDispute()`:

```solidity
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

        // Return disputer's bond
        _transferToken(req.bondToken, disputer[requestId], bondAmount);

        // Update answer and winners
        _finalAnswers[requestId] = newAnswer;
        _winners[requestId] = newWinners;
    } else {
        // Forfeit disputer's bond: 50% to winners, 50% to requester
        _distributeForfeitedBond(requestId, req.bondToken, bondAmount, req.requester);
    }

    // Open second dispute window (for DAO escalation)
    phases[requestId] = Phase.DisputeWindow;
    disputeWindowEnd[requestId] = block.timestamp + disputeWindow;

    emit DisputeResolved(requestId, overturn, _finalAnswers[requestId]);
    emit DisputeWindowOpened(requestId, disputeWindowEnd[requestId]);
}
```

- [ ] **Step 6: Implement `_distributeForfeitedBond()` and `_transferToken()` helpers**

Add in the Internal section:

```solidity
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
    uint256 winnersTotal = bondAmount - requesterShare; // Handles odd amounts
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
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `forge test --match-test "test_resolveDispute" -v`
Expected: All PASS

- [ ] **Step 8: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: implement resolveDispute with bond forfeiture/refund"
```

---

### Task 7: Implement `initiateDAOEscalation()`

**Files:**
- Modify: `src/NousOracle.sol`
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test — DAO escalation happy path**

```solidity
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

    // Resolve dispute (upheld) to open second window
    address dJudge = oracle.disputeJudge(requestId);
    vm.prank(dJudge);
    oracle.resolveDispute(requestId, false, "", new address[](0));

    // Now in DisputeWindow with disputeUsed=true — can escalate to DAO
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
```

- [ ] **Step 2: Write failing test — cannot escalate before dispute**

```solidity
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

    // In first DisputeWindow — disputeUsed is false, should revert
    address escalator = makeAddr("escalator");
    taikoToken.mint(escalator, 10 ether);

    vm.startPrank(escalator);
    taikoToken.approve(address(oracle), 1 ether);
    vm.expectRevert(); // disputeUsed is false
    oracle.initiateDAOEscalation(requestId);
    vm.stopPrank();
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `forge test --match-test "test_initiateDAOEscalation" -v`
Expected: FAIL

- [ ] **Step 4: Implement `initiateDAOEscalation()`**

Add after `resolveDispute()`:

```solidity
/// @notice Escalate to DAO after dispute resolution.
/// @param requestId The request to escalate.
function initiateDAOEscalation(uint256 requestId) external {
    _requirePhase(requestId, Phase.DisputeWindow);
    if (block.timestamp >= disputeWindowEnd[requestId]) revert DisputeWindowNotOpen(requestId);
    if (!disputeUsed[requestId]) revert DisputeRequired(requestId); // Must have had a dispute first
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `forge test --match-test "test_initiateDAOEscalation" -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: implement initiateDAOEscalation with ERC-20 bond"
```

---

### Task 8: Implement `resolveDAOEscalation()` and `timeoutDAOEscalation()`

**Files:**
- Modify: `src/NousOracle.sol`
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test — DAO upholds**

```solidity
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

function test_resolveDAOEscalation_upheld() public {
    uint256 requestId = _createDefaultRequest(2);
    (address dao, MockERC20 taikoToken) = _driveToDAOEscalation(requestId);

    // Get current winners for share calculation
    address[] memory currentWinners = oracle.getWinners(requestId);
    uint256 escalationBond = oracle.daoEscalationBondPaid(requestId);

    uint256 winnersTokenBefore = taikoToken.balanceOf(currentWinners[0]);
    uint256 requesterTokenBefore = taikoToken.balanceOf(requester);

    vm.prank(dao);
    oracle.resolveDAOEscalation(requestId, false, "", new address[](0));

    // Phase should be DisputeWindow with immediately expired window
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
    assertLe(oracle.disputeWindowEnd(requestId), block.timestamp);

    // Escalator bond forfeited: 50% to winners, 50% to requester (in Taiko ERC-20)
    uint256 winnersShare = escalationBond / 2;
    uint256 requesterShareExpected = escalationBond / 2;
    assertEq(taikoToken.balanceOf(currentWinners[0]), winnersTokenBefore + winnersShare);
    assertEq(taikoToken.balanceOf(requester), requesterTokenBefore + requesterShareExpected);
}
```

- [ ] **Step 2: Write failing test — DAO overturns**

```solidity
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

    // Escalator bond returned
    assertEq(taikoToken.balanceOf(escalator), escalatorTokenBefore + escalationBond);

    // Winners updated
    address[] memory updated = oracle.getWinners(requestId);
    assertEq(updated[0], agent2);

    // Can distribute immediately (window already expired)
    oracle.distributeRewards(requestId);
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
}
```

- [ ] **Step 3: Write failing test — DAO timeout**

```solidity
function test_timeoutDAOEscalation() public {
    uint256 requestId = _createDefaultRequest(2);
    (address dao, MockERC20 taikoToken) = _driveToDAOEscalation(requestId);

    address escalator = oracle.daoEscalator(requestId);
    uint256 escalatorTokenBefore = taikoToken.balanceOf(escalator);
    uint256 escalationBond = oracle.daoEscalationBondPaid(requestId);

    // DAO doesn't act — warp past deadline
    vm.warp(block.timestamp + 7 days + 1);

    // Anyone can call timeout
    oracle.timeoutDAOEscalation(requestId);

    // Escalator bond returned (DAO failed, not escalator's fault)
    assertEq(taikoToken.balanceOf(escalator), escalatorTokenBefore + escalationBond);

    // Phase is DisputeWindow with expired window — can distribute
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.DisputeWindow));
    assertLe(oracle.disputeWindowEnd(requestId), block.timestamp);

    oracle.distributeRewards(requestId);
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `forge test --match-test "test_resolveDAOEscalation|test_timeoutDAOEscalation" -v`
Expected: All FAIL

- [ ] **Step 5: Implement `resolveDAOEscalation()`**

Add after `initiateDAOEscalation()`:

```solidity
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

        // Return escalator's bond
        IERC20(daoEscalationBondToken).safeTransfer(daoEscalator[requestId], bondAmount);

        // Update answer and winners
        _finalAnswers[requestId] = newAnswer;
        _winners[requestId] = newWinners;
    } else {
        // Forfeit escalator's bond: 50% to winners, 50% to requester
        Request storage req = _requests[requestId];
        _distributeForfeitedBond(requestId, daoEscalationBondToken, bondAmount, req.requester);
    }

    // DAO is final — set immediately expired window
    phases[requestId] = Phase.DisputeWindow;
    disputeWindowEnd[requestId] = block.timestamp;

    emit DAOEscalationResolved(requestId, overturn ? newAnswer : _finalAnswers[requestId]);
}
```

- [ ] **Step 6: Implement `timeoutDAOEscalation()`**

```solidity
/// @notice Timeout a DAO escalation if the DAO fails to act.
///         Anyone can call after the deadline passes.
/// @param requestId The escalated request.
function timeoutDAOEscalation(uint256 requestId) external {
    _requirePhase(requestId, Phase.DAOEscalation);
    if (block.timestamp <= daoEscalationDeadline[requestId]) revert DAODeadlineNotPassed(requestId);

    // Return escalator's bond (DAO failed to act)
    IERC20(daoEscalationBondToken).safeTransfer(
        daoEscalator[requestId],
        daoEscalationBondPaid[requestId]
    );

    // Dispute judge's decision stands, immediately distributable
    phases[requestId] = Phase.DisputeWindow;
    disputeWindowEnd[requestId] = block.timestamp;

    emit DAOEscalationTimedOut(requestId);
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `forge test --match-test "test_resolveDAOEscalation|test_timeoutDAOEscalation" -v`
Expected: All PASS

- [ ] **Step 8: Commit**

```bash
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: implement resolveDAOEscalation and timeoutDAOEscalation"
```

---

### Task 9: Full E2E Dispute Flow Test

**Files:**
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Write full E2E test — create → commit → reveal → judge → dispute → DAO → distribute**

```solidity
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

    // 8. DAO overturns back to agent1
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

    // Both winners should have received rewards
    assertGt(agent1.balance, agent1Bal);
    assertGt(agent2.balance, agent2Bal);

    // Verify getResolution now returns finalized
    (, bool finalized) = oracle.getResolution(requestId);
    assertTrue(finalized);
}
```

- [ ] **Step 2: Run the test**

Run: `forge test --match-test test_fullDisputeFlow_E2E -v`
Expected: PASS

- [ ] **Step 3: Run ALL tests to verify nothing is broken**

Run: `forge test -v`
Expected: All PASS

- [ ] **Step 4: Commit**

```bash
git add test/NousOracle.t.sol
git commit -m "test: add full E2E dispute flow test"
```

---

### Task 10: Setter Validation & Edge Case Tests

**Files:**
- Modify: `test/NousOracle.t.sol`

- [ ] **Step 1: Write tests for setter validations**

```solidity
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

    // At exact deadline — dispute should fail (strict less-than)
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

    // Skip dispute, warp past window, distribute directly
    vm.warp(block.timestamp + 1 hours + 1);

    uint256 agent1Bal = agent1.balance;
    oracle.distributeRewards(requestId);
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
    assertGt(agent1.balance, agent1Bal);
}
```

- [ ] **Step 2: Write test — insufficient dispute bond reverts**

```solidity
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

    // Send less than required
    vm.prank(disputerAddr);
    vm.expectRevert(abi.encodeWithSelector(NousOracle.InsufficientDisputeBond.selector, disputeBondRequired, 0.01 ether));
    oracle.initiateDispute{value: 0.01 ether}(requestId, "Underfunded");
}
```

- [ ] **Step 3: Write test — DAO escalation reverts if DAO not set**

```solidity
function test_initiateDAOEscalation_revertsIfDAONotSet() public {
    MockERC20 taikoToken = new MockERC20();

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDaoEscalationBondToken(address(taikoToken));
    oracle.setDaoEscalationBond(1 ether);
    // NOTE: daoAddress NOT set (remains address(0))
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
```

- [ ] **Step 4: Write test — DAO escalation reverts if already used**

```solidity
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

    // First escalation succeeds
    address escalator1 = makeAddr("escalator1");
    taikoToken.mint(escalator1, 10 ether);
    vm.startPrank(escalator1);
    taikoToken.approve(address(oracle), 1 ether);
    oracle.initiateDAOEscalation(requestId);
    vm.stopPrank();

    // DAO resolves
    vm.prank(dao);
    oracle.resolveDAOEscalation(requestId, false, "", new address[](0));

    // Second escalation should fail — but phase is now DisputeWindow with expired window
    // and daoEscalationUsed is true. distributeRewards should work instead.
    // The actual revert would be because the window is already expired (disputeWindowEnd = block.timestamp)
    address escalator2 = makeAddr("escalator2");
    taikoToken.mint(escalator2, 10 ether);
    vm.startPrank(escalator2);
    taikoToken.approve(address(oracle), 1 ether);
    vm.expectRevert(); // Window expired or escalation already used
    oracle.initiateDAOEscalation(requestId);
    vm.stopPrank();
}
```

- [ ] **Step 5: Run all tests**

Run: `forge test -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add test/NousOracle.t.sol
git commit -m "test: add setter validation, bond validation, and DAO escalation guard tests"
```

---

### Task 11: Update Client TypeScript & Web UI

**Files:**
- Modify: `client/src/types.ts:3-10`
- Modify: `client/src/chain.ts:29-39`
- Modify: `web/index.html:1570`

- [ ] **Step 1: Update `PhaseName` union in `client/src/types.ts`**

Change:

```typescript
export type PhaseName =
  | 'none'
  | 'committing'
  | 'revealing'
  | 'judging'
  | 'finalized'
  | 'distributed'
  | 'failed';
```

to:

```typescript
export type PhaseName =
  | 'none'
  | 'committing'
  | 'revealing'
  | 'judging'
  | 'finalized'
  | 'distributed'
  | 'failed'
  | 'disputeWindow'
  | 'disputed'
  | 'daoEscalation';
```

- [ ] **Step 2: Update `PHASE_NAMES` and `ACTIVE_PHASES` in `client/src/chain.ts`**

Change `PHASE_NAMES`:

```typescript
const PHASE_NAMES: Record<number, PhaseName> = {
  0: 'none',
  1: 'committing',
  2: 'revealing',
  3: 'judging',
  4: 'finalized',
  5: 'distributed',
  6: 'failed',
  7: 'disputeWindow',
  8: 'disputed',
  9: 'daoEscalation',
};
```

Change `ACTIVE_PHASES`:

```typescript
const ACTIVE_PHASES = new Set<PhaseName>(['committing', 'revealing', 'judging', 'finalized', 'disputeWindow', 'disputed', 'daoEscalation']);
```

- [ ] **Step 3: Update `PHASE_NAMES` in `web/index.html`**

Change:

```javascript
const PHASE_NAMES = ['none', 'committing', 'revealing', 'judging', 'finalized', 'distributed', 'failed'];
```

to:

```javascript
const PHASE_NAMES = ['none', 'committing', 'revealing', 'judging', 'finalized', 'distributed', 'failed', 'dispute window', 'disputed', 'dao escalation'];
```

- [ ] **Step 4: Update the web UI phase display logic**

In `web/index.html`, find the line:

```javascript
if (phase === 'finalized' || phase === 'distributed') {
```

Change to:

```javascript
if (phase === 'finalized' || phase === 'distributed' || phase === 'dispute window' || phase === 'disputed' || phase === 'dao escalation') {
```

This ensures the UI shows final answer and reasoning for all post-judging phases.

- [ ] **Step 5: Verify client builds**

Run: `cd client && npm run build`
Expected: Compiles successfully

- [ ] **Step 6: Commit**

```bash
git add client/src/types.ts client/src/chain.ts web/index.html
git commit -m "feat: update client and web UI for dispute resolution phases"
```

---

### Task 12: Run Full Test Suite & Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full Foundry test suite**

Run: `forge test -v`
Expected: All tests PASS

- [ ] **Step 2: Run client tests**

Run: `cd client && npm test`
Expected: All tests PASS (phaseFromIndex test may need update for new values)

- [ ] **Step 3: Verify forge build is clean**

Run: `forge build`
Expected: No warnings, clean compilation

- [ ] **Step 4: Commit any final fixes**

If any tests needed small adjustments, commit them.

---

## Deployment Note: Post-Upgrade Configuration

After deploying the upgraded implementation via UUPS proxy, the owner MUST call these setters to enable dispute resolution (storage defaults to zero for new variables):

```bash
# Required — without these, dispute window is 0 seconds (disputes impossible)
setDisputeWindow(3600)              # 1 hour
setDisputeBondMultiplier(150)       # 1.5x original bond

# Required for DAO escalation — without these, DAO escalation is disabled
setDaoAddress(<dao_multisig>)
setDaoEscalationBondToken(<taiko_token_address>)
setDaoEscalationBond(<amount_in_wei>)
setDaoResolutionWindow(604800)      # 7 days
```

This is by design — dispute parameters are owner-configurable and not set in the initializer (which cannot be re-called on an existing proxy). All tests use `setUp` to configure these values explicitly.
