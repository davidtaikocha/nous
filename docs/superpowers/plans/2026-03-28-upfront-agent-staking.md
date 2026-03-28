# Upfront Agent Staking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-request bond model with global upfront staking — agents register with stake before being selected for requests.

**Architecture:** Add staking storage, registration, withdrawal, and slashing to `NousOracle.sol`. Modify `createRequest()` to select agents randomly from the registered pool. Modify `commit()` to check selection instead of collecting bonds. Modify `distributeRewards()` to distribute slashed stake to winners. Maintain backward compatibility for in-flight pre-upgrade requests.

**Tech Stack:** Solidity 0.8.28, Foundry (forge), TypeScript, viem, HTML/JS frontend

**Spec:** `docs/superpowers/specs/2026-03-28-upfront-agent-staking-design.md`

---

### Task 1: Add Staking Storage, Enum, Struct, and Registration

**Files:**
- Modify: `src/NousOracle.sol:15-132` (storage section)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for agent registration**

Add to `test/NousOracle.t.sol` after the existing test constants (line ~33):

```solidity
uint256 constant MIN_STAKE = 0.5 ether;
uint256 constant SLASH_PCT = 5000; // 50% in basis points
uint256 constant WITHDRAW_COOLDOWN = 1 days;
```

Add a new setup helper after the existing `setUp()` function. We need a separate setup that configures staking params. Add this after `setUp()`:

```solidity
function _setupStaking() internal {
    vm.startPrank(owner);
    oracle.setMinStakeAmount(MIN_STAKE);
    oracle.setSlashPercentage(SLASH_PCT);
    oracle.setWithdrawalCooldown(WITHDRAW_COOLDOWN);
    vm.stopPrank();
}
```

Then add the test:

```solidity
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_registerAgent_info -vvv`
Expected: Compilation error — `AgentRole`, `agentStakes`, `registerAgent`, staking config functions don't exist yet.

- [ ] **Step 3: Add staking enum, struct, storage, and events to NousOracle.sol**

In `src/NousOracle.sol`, add after the `Phase` enum (after line 31):

```solidity
enum AgentRole { Info, Judge }

struct AgentStake {
    uint256 amount;
    AgentRole role;
    bool registered;
    uint256 withdrawRequestTime;
}
```

Add new storage variables after `requestDisputeWindow` mapping (after line 132):

```solidity
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
```

Add staking events after the existing dispute events (after line 168):

```solidity
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
```

Add staking errors after the existing dispute errors (after line 186):

```solidity
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
```

- [ ] **Step 4: Add staking config functions**

Add after the existing dispute configuration section (after line 287) in `src/NousOracle.sol`:

```solidity
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
```

- [ ] **Step 5: Add registerAgent() function**

Add after the staking configuration section in `src/NousOracle.sol`:

```solidity
// ============ Agent Staking ============

/// @notice Register as an agent with a stake.
/// @param role The agent role (Info or Judge).
function registerAgent(AgentRole role) external payable {
    if (agentStakes[msg.sender].registered) revert AlreadyRegistered(msg.sender);

    uint256 stakeAmount;
    if (stakeToken == address(0)) {
        stakeAmount = msg.value;
    } else {
        stakeAmount = msg.value; // Will be overridden below
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);
    }

    if (stakeAmount < minStakeAmount) revert InsufficientStake(minStakeAmount, stakeAmount);

    agentStakes[msg.sender] = AgentStake({
        amount: stakeAmount,
        role: role,
        registered: true,
        withdrawRequestTime: 0
    });

    if (role == AgentRole.Info) {
        _registeredInfoAgents.push(msg.sender);
    } else {
        _registeredJudges.push(msg.sender);
    }

    emit AgentRegistered(msg.sender, role, stakeAmount);
}
```

Wait — the ERC-20 path has a bug. For ERC-20 staking, the amount can't come from `msg.value`. Let me fix: for ERC-20, we need an explicit `amount` parameter, or we read the amount from `msg.value` for ETH and require a separate flow for ERC-20. The simplest approach consistent with the rest of the codebase (which uses `msg.value` for ETH and `safeTransferFrom` for ERC-20): accept an `amount` parameter.

Replace the above `registerAgent` with:

```solidity
/// @notice Register as an agent with a stake.
/// @param role The agent role (Info or Judge).
function registerAgent(AgentRole role) external payable {
    if (agentStakes[msg.sender].registered) revert AlreadyRegistered(msg.sender);

    uint256 stakeAmount;
    if (stakeToken == address(0)) {
        stakeAmount = msg.value;
    } else {
        // For ERC-20 staking, msg.value must be 0, stake amount = minStakeAmount
        // Agent can top up later with addStake()
        if (msg.value > 0) revert ETHSentWithERC20Bond();
        stakeAmount = minStakeAmount;
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), stakeAmount);
    }

    if (stakeAmount < minStakeAmount) revert InsufficientStake(minStakeAmount, stakeAmount);

    agentStakes[msg.sender] = AgentStake({
        amount: stakeAmount,
        role: role,
        registered: true,
        withdrawRequestTime: 0
    });

    if (role == AgentRole.Info) {
        _registeredInfoAgents.push(msg.sender);
    } else {
        _registeredJudges.push(msg.sender);
    }

    emit AgentRegistered(msg.sender, role, stakeAmount);
}
```

- [ ] **Step 6: Add view functions for registered agents**

Add after `registerAgent()`:

```solidity
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
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_registerAgent_info -vvv`
Expected: PASS

- [ ] **Step 8: Write test for registration edge cases**

```solidity
function test_registerAgent_judge() public {
    _setupStaking();

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
```

- [ ] **Step 9: Run edge case tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_registerAgent_" -vvv`
Expected: ALL PASS

- [ ] **Step 10: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: add agent staking storage, registration, and config"
```

---

### Task 2: Add Stake Top-Up and Withdrawal

**Files:**
- Modify: `src/NousOracle.sol`
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing tests for addStake and withdrawal**

```solidity
// ============ Stake Top-Up Tests ============

function test_addStake() public {
    _setupStaking();

    vm.prank(agent1);
    oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);

    vm.prank(agent1);
    oracle.addStake{value: 0.5 ether}();

    (uint256 amount,,,) = oracle.agentStakes(agent1);
    assertEq(amount, 1 ether);
}

function test_addStake_revertsIfNotRegistered() public {
    _setupStaking();

    vm.expectRevert(abi.encodeWithSelector(NousOracle.NotRegistered.selector, agent1));
    vm.prank(agent1);
    oracle.addStake{value: 0.5 ether}();
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

function test_requestWithdrawal_revertsIfActiveAssignments() public {
    _setupStaking();

    // Register 2 info agents and 1 judge (needed for createRequest)
    vm.prank(agent1);
    oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);
    vm.prank(agent2);
    oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);
    vm.prank(judge1);
    oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Judge);

    // Create a request that selects agents
    vm.prank(requester);
    oracle.createRequest{value: REWARD}(
        "test", 2, REWARD, 0,
        block.timestamp + 1 hours, address(0), address(0),
        "specs", _defaultCapabilities()
    );

    // Agent1 should have active assignment now, so withdrawal should revert
    vm.expectRevert(abi.encodeWithSelector(NousOracle.ActiveAssignmentsPending.selector, agent1, 1));
    vm.prank(agent1);
    oracle.requestWithdrawal();
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_addStake|test_requestWithdrawal|test_executeWithdrawal|test_cancelWithdrawal" -vvv`
Expected: Compilation errors — functions don't exist yet.

- [ ] **Step 3: Implement addStake()**

Add after `registerAgent()` in `src/NousOracle.sol`:

```solidity
/// @notice Add more stake to an existing registration.
function addStake() external payable {
    AgentStake storage stake = agentStakes[msg.sender];
    if (!stake.registered && stake.withdrawRequestTime == 0) revert NotRegistered(msg.sender);

    uint256 added;
    if (stakeToken == address(0)) {
        added = msg.value;
    } else {
        if (msg.value > 0) revert ETHSentWithERC20Bond();
        added = msg.value; // placeholder
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), added);
    }

    stake.amount += added;
    emit StakeAdded(msg.sender, added, stake.amount);
}
```

Wait, the ERC-20 path for `addStake` also needs an explicit amount. Let me rethink — for simplicity and consistency with ETH path, let's add an overloaded version or just accept msg.value for ETH. For ERC-20, we need an amount param. The cleanest approach: add an `amount` parameter for ERC-20 staking. Actually, looking at the existing codebase patterns, the simpler approach is: for ETH staking (`stakeToken == address(0)`), use `msg.value`. For ERC-20, accept an explicit amount parameter. Let me add that:

```solidity
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
```

Update the test to pass `0` as the amount parameter since we're using ETH:
```solidity
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
```

- [ ] **Step 4: Implement withdrawal functions**

Add after `addStake()` in `src/NousOracle.sol`:

```solidity
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

    // Remove from pool
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
```

- [ ] **Step 5: Add _removeFromArray helper**

Add in the internal section of `src/NousOracle.sol` (near the other internal functions):

```solidity
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
```

- [ ] **Step 6: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_addStake|test_requestWithdrawal|test_executeWithdrawal|test_cancelWithdrawal" -vvv`
Expected: PASS (the `test_requestWithdrawal_revertsIfActiveAssignments` test will fail since createRequest doesn't select agents yet — we'll skip that test for now and come back in Task 3)

Note: Comment out `test_requestWithdrawal_revertsIfActiveAssignments` for now — it depends on Task 3's `createRequest` changes.

- [ ] **Step 7: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: add stake top-up and withdrawal with cooldown"
```

---

### Task 3: Modify createRequest() for Agent Selection

**Files:**
- Modify: `src/NousOracle.sol:291-339` (createRequest function)
- Modify: `src/IAgentCouncilOracle.sol:15-26` (Request struct), `53-63` (createRequest signature)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for agent selection on createRequest**

```solidity
// ============ Staking: Agent Selection Tests ============

function _registerInfoAgent(address agent) internal {
    vm.prank(agent);
    oracle.registerAgent{value: MIN_STAKE}(NousOracle.AgentRole.Info);
}

function _registerJudgeAgent(address judge) internal {
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
        0, // bondAmount = 0 for new staking model
        block.timestamp + 1 hours,
        address(0),
        address(0),
        "Return JSON with temperature and conditions",
        _defaultCapabilities()
    );
}

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_createRequest_selectsAgents|test_createRequest_revertsIfInsufficientRegisteredAgents" -vvv`
Expected: FAIL — createRequest doesn't select agents yet.

- [ ] **Step 3: Modify createRequest() to select agents**

In `src/NousOracle.sol`, modify `createRequest()`. The key change: when `bondAmount == 0` (new staking model), select agents from the registered pool. When `bondAmount > 0` (legacy), keep existing behavior.

Replace the validation section at the start of `createRequest()` (lines 303-305) with:

```solidity
if (deadline <= block.timestamp) revert DeadlineMustBeFuture();
if (numInfoAgents == 0) revert NumInfoAgentsMustBePositive();

// New staking model: select from registered pool
bool isStakingModel = (bondAmount == 0);
if (isStakingModel) {
    if (_registeredInfoAgents.length < numInfoAgents) {
        revert InsufficientRegisteredAgents(numInfoAgents, _registeredInfoAgents.length);
    }
    if (_registeredJudges.length == 0) revert NoJudgesAvailable();
} else {
    // Legacy bond model
    if (_judgeList.length == 0) revert NoJudgesAvailable();
}
```

After storing the request (after line 336 `phases[requestId] = Phase.Committing;`), add agent selection:

```solidity
phases[requestId] = Phase.Committing;

// Select agents if using staking model
if (isStakingModel) {
    _selectInfoAgents(requestId, numInfoAgents);
}

emit RequestCreated(requestId, msg.sender, query, rewardAmount, numInfoAgents, bondAmount);
```

- [ ] **Step 4: Implement _selectInfoAgents()**

Add as an internal function:

```solidity
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
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_createRequest_selectsAgents|test_createRequest_revertsIfInsufficientRegisteredAgents" -vvv`
Expected: PASS

- [ ] **Step 6: Verify existing tests still pass**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: All existing tests PASS (they use `bondAmount > 0`, so they hit the legacy path).

- [ ] **Step 7: Uncomment test_requestWithdrawal_revertsIfActiveAssignments and run it**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_requestWithdrawal_revertsIfActiveAssignments -vvv`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: select agents from registered pool on createRequest"
```

---

### Task 4: Modify commit() for Staking Model

**Files:**
- Modify: `src/NousOracle.sol:342-378` (commit function)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for staking-model commit**

```solidity
// ============ Staking: Commit Tests ============

function test_commit_stakingModel() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    // Selected agent can commit without sending ETH
    bytes32 commitment = keccak256(abi.encode("answer1", uint256(1)));
    vm.prank(selected[0]);
    oracle.commit(requestId, commitment);

    (address[] memory agents, bytes32[] memory hashes) = oracle.getCommits(requestId);
    assertEq(agents.length, 1);
    assertEq(agents[0], selected[0]);
    assertEq(hashes[0], commitment);
}

function test_commit_stakingModel_revertsIfNotSelected() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerInfoAgent(agent3);
    _registerJudgeAgent(judge1);

    uint256 requestId = _createStakedRequest(1);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    // Find an agent that was NOT selected
    address notSelected;
    for (uint256 i; i < 3; i++) {
        address candidate = i == 0 ? agent1 : (i == 1 ? agent2 : agent3);
        if (candidate != selected[0]) {
            notSelected = candidate;
            break;
        }
    }

    vm.expectRevert(abi.encodeWithSelector(NousOracle.NotSelectedForRequest.selector, requestId, notSelected));
    vm.prank(notSelected);
    oracle.commit(requestId, keccak256(abi.encode("answer", uint256(1))));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_commit_stakingModel" -vvv`
Expected: FAIL — commit still requires bond payment.

- [ ] **Step 3: Modify commit() for dual-mode operation**

Replace the `commit()` function in `src/NousOracle.sol` (lines 342-378):

```solidity
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
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_commit" -vvv`
Expected: ALL PASS (both staking and legacy commit tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: commit checks selection for staking model, bond for legacy"
```

---

### Task 5: Implement Slashing

**Files:**
- Modify: `src/NousOracle.sol` (endCommitPhase, endRevealPhase, aggregate)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for slash on no-commit**

```solidity
// ============ Staking: Slashing Tests ============

function test_slash_noCommit() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    uint256 requestId = _createStakedRequest(2);

    // Only one agent commits
    address[] memory selected = oracle.getSelectedAgents(requestId);
    bytes32 commitment = keccak256(abi.encode(abi.encode("answer"), uint256(1)));
    vm.prank(selected[0]);
    oracle.commit(requestId, commitment);

    // Deadline passes, end commit phase — non-committer should be slashed
    vm.warp(block.timestamp + 1 hours + 1);
    oracle.endCommitPhase(requestId);

    // Non-committing agent should have been slashed
    (uint256 remainingStake,,,) = oracle.agentStakes(selected[1]);
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    assertEq(remainingStake, MIN_STAKE - expectedSlash);

    // Slashed amount should accumulate in request
    assertEq(oracle.requestSlashedStake(requestId), expectedSlash);
}

function test_slash_noReveal() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);

    // Both commit
    bytes memory a1 = abi.encode("sunny");
    bytes memory a2 = abi.encode("cloudy");
    bytes32 c1 = keccak256(abi.encode(a1, uint256(1)));
    bytes32 c2 = keccak256(abi.encode(a2, uint256(2)));

    vm.prank(selected[0]);
    oracle.commit(requestId, c1);
    vm.prank(selected[1]);
    oracle.commit(requestId, c2);

    // Only first reveals
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 1);

    // Reveal deadline passes, end reveal phase — non-revealer should be slashed
    vm.warp(block.timestamp + revealDuration() + 1);
    oracle.endRevealPhase(requestId);

    (uint256 remainingStake,,,) = oracle.agentStakes(selected[1]);
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    assertEq(remainingStake, MIN_STAKE - expectedSlash);
}

function test_slash_loser() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

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

    // Judge picks only selected[0] as winner
    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];

    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("better"));

    // Loser should be slashed
    (uint256 loserStake,,,) = oracle.agentStakes(selected[1]);
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    assertEq(loserStake, MIN_STAKE - expectedSlash);

    // Winner stake should be untouched
    (uint256 winnerStake,,,) = oracle.agentStakes(selected[0]);
    assertEq(winnerStake, MIN_STAKE);
}
```

We need a `revealDuration()` helper in the test. Add to the test helpers section:

```solidity
function revealDuration() internal view returns (uint256) {
    return REVEAL_DURATION;
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_slash_" -vvv`
Expected: FAIL — slashing logic doesn't exist yet.

- [ ] **Step 3: Add _slashAgent internal helper**

Add to internal section of `src/NousOracle.sol`:

```solidity
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

/// @dev Decrement active assignments for an agent.
function _decrementAssignment(address agent) internal {
    if (activeAssignments[agent] > 0) {
        activeAssignments[agent] -= 1;
    }
}
```

- [ ] **Step 4: Add slashing to endCommitPhase()**

In `endCommitPhase()`, after the "No agents committed" check (after line 394), add slashing for non-committing selected agents when using staking model. Before `phases[requestId] = Phase.Revealing;`:

```solidity
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
            uint256 slashed = _slashAgent(selected[i]);
            requestSlashedStake[requestId] += slashed;
            _decrementAssignment(selected[i]);
        }
    }
}
```

Also need to handle the "no agents committed" case for staking model — slash all selected and refund:

In the `if (_committedAgents[requestId].length == 0)` block, before `phases[requestId] = Phase.Failed;`, add:

```solidity
// Slash all selected agents for not committing (staking model)
if (req.bondAmount == 0) {
    address[] storage selected = _selectedAgents[requestId];
    for (uint256 i; i < selected.length; ++i) {
        _slashAgent(selected[i]);
        _decrementAssignment(selected[i]);
    }
}
```

- [ ] **Step 5: Add slashing to endRevealPhase()**

In `endRevealPhase()`, before calling `_transitionToJudging(requestId)`, add slashing for non-revealers:

```solidity
// Slash non-revealers (staking model only)
Request storage req = _requests[requestId];
if (req.bondAmount == 0) {
    for (uint256 i; i < _committedAgents[requestId].length; ++i) {
        address agent = _committedAgents[requestId][i];
        if (!hasRevealed[requestId][agent]) {
            uint256 slashed = _slashAgent(agent);
            requestSlashedStake[requestId] += slashed;
            _decrementAssignment(agent);
        }
    }
}
```

Also in the quorum-not-met failure branch, slash non-revealers and decrement assignments:

```solidity
if (revealed < quorum) {
    phases[requestId] = Phase.Failed;
    _refundRequester(requestId);
    if (req.bondAmount == 0) {
        // Staking model: slash non-revealers, decrement all selected
        for (uint256 i; i < _committedAgents[requestId].length; ++i) {
            address agent = _committedAgents[requestId][i];
            if (!hasRevealed[requestId][agent]) {
                _slashAgent(agent);
            }
            _decrementAssignment(agent);
        }
        // Also decrement non-committers
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
```

- [ ] **Step 6: Add slashing to aggregate()**

In `aggregate()`, after recording winners, slash losers (staking model only). Add before setting phase to DisputeWindow:

```solidity
// Slash losers (staking model only)
if (req.bondAmount == 0) {
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
            uint256 slashed = _slashAgent(agent);
            requestSlashedStake[requestId] += slashed;
        }
    }
}
```

Need to add `Request storage req = _requests[requestId];` at the top of `aggregate()` if not already there.

- [ ] **Step 7: Run slashing tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_slash_" -vvv`
Expected: ALL PASS

- [ ] **Step 8: Run full test suite**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS (legacy tests unaffected)

- [ ] **Step 9: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: implement stake slashing for no-commit, no-reveal, and losing"
```

---

### Task 6: Modify distributeRewards() and Judge Selection

**Files:**
- Modify: `src/NousOracle.sol:485-535` (distributeRewards), `753-765` (_transitionToJudging)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for staking-model reward distribution**

```solidity
// ============ Staking: Reward Distribution Tests ============

function test_distributeRewards_stakingModel() public {
    _setupStaking();
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerJudgeAgent(judge1);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
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

    // Judge picks selected[0] as sole winner
    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];

    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("better"));

    // Wait for dispute window
    vm.warp(block.timestamp + 1 hours + 1);

    uint256 winnerBalanceBefore = selected[0].balance;
    oracle.distributeRewards(requestId);

    // Winner gets: reward (1 ether) + slashed stake from loser
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    uint256 expectedPayout = REWARD + expectedSlash;
    assertEq(selected[0].balance, winnerBalanceBefore + expectedPayout);

    // Both agents should have activeAssignments decremented
    assertEq(oracle.activeAssignments(selected[0]), 0);
    assertEq(oracle.activeAssignments(selected[1]), 0);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_distributeRewards_stakingModel -vvv`
Expected: FAIL — distributeRewards still uses legacy bond math.

- [ ] **Step 3: Modify distributeRewards() for dual-mode**

Replace `distributeRewards()` in `src/NousOracle.sol`:

```solidity
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
        // Staking model: reward + slashed stake to winners
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
        // Non-committers are already decremented in endCommitPhase().
        // Non-revealers are already decremented in endRevealPhase().
        for (uint256 i; i < _revealedAgents[requestId].length; ++i) {
            _decrementAssignment(_revealedAgents[requestId][i]);
        }

        phases[requestId] = Phase.Distributed;
        emit RewardsDistributed(requestId, winnerList, amounts);
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
```

- [ ] **Step 4: Modify _transitionToJudging() for staking model**

Replace `_transitionToJudging()`:

```solidity
function _transitionToJudging(uint256 requestId) internal {
    Request storage req = _requests[requestId];
    bool isStakingModel = (req.bondAmount == 0);

    address[] storage judgePool = isStakingModel ? _registeredJudges : _judgeList;
    uint256 judgeCount = judgePool.length;
    if (judgeCount == 0) revert NoJudgesAvailable();

    uint256 seed = uint256(keccak256(abi.encode(blockhash(block.number - 1), requestId)));
    address judge = judgePool[seed % judgeCount];

    selectedJudge[requestId] = judge;
    phases[requestId] = Phase.Judging;

    emit JudgeSelected(requestId, judge);
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_distributeRewards" -vvv`
Expected: ALL PASS (both staking and legacy tests)

- [ ] **Step 6: Run full test suite**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: dual-mode distributeRewards and judge selection from staking pool"
```

---

### Task 7: Update Dispute Bond for Staking Model

**Files:**
- Modify: `src/NousOracle.sol:542-572` (initiateDispute), `855-878` (_selectDisputeJudge)
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write failing test for flat dispute bond**

```solidity
// ============ Staking: Dispute Bond Tests ============

function test_initiateDispute_stakingModel() public {
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

    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, abi.encode("sunny"), winners, abi.encode("better"));

    // Dispute with flat bond (not bondAmount * multiplier)
    address disputerAddr = makeAddr("disputerStaking");
    vm.deal(disputerAddr, 1 ether);
    vm.prank(disputerAddr);
    oracle.initiateDispute{value: 0.2 ether}(requestId, "Disagree");

    assertEq(oracle.disputeBondPaid(requestId), 0.2 ether);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_initiateDispute_stakingModel -vvv`
Expected: FAIL — `disputeBondAmount` function doesn't exist or dispute logic uses `bondAmount * multiplier`.

- [ ] **Step 3: Modify initiateDispute() for dual-mode**

In `initiateDispute()`, change the bond calculation (around line 548):

```solidity
Request storage req = _requests[requestId];
uint256 requiredBond;
if (req.bondAmount == 0) {
    // Staking model: use flat dispute bond
    requiredBond = disputeBondAmount;
} else {
    // Legacy: bondAmount * multiplier
    requiredBond = req.bondAmount * disputeBondMultiplier / 100;
}
```

- [ ] **Step 4: Modify _selectDisputeJudge() for staking model**

Replace `_selectDisputeJudge()`:

```solidity
function _selectDisputeJudge(uint256 requestId) internal {
    address originalJudge = selectedJudge[requestId];
    Request storage req = _requests[requestId];
    bool isStakingModel = (req.bondAmount == 0);

    address[] storage judgePool = isStakingModel ? _registeredJudges : _judgeList;
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
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test "test_initiateDispute" -vvv`
Expected: ALL PASS (both staking and legacy dispute tests)

- [ ] **Step 6: Run full test suite**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 7: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add src/NousOracle.sol test/NousOracle.t.sol
git commit -m "feat: flat dispute bond for staking model, dual-mode judge selection"
```

---

### Task 8: Full E2E Staking Test

**Files:**
- Test: `test/NousOracle.t.sol`

- [ ] **Step 1: Write full end-to-end staking flow test**

```solidity
// ============ Staking: Full E2E Test ============

function test_fullFlow_stakingModel() public {
    _setupStaking();

    // Register agents
    _registerInfoAgent(agent1);
    _registerInfoAgent(agent2);
    _registerInfoAgent(agent3);
    _registerJudgeAgent(judge1);
    _registerJudgeAgent(judge2);

    vm.startPrank(owner);
    oracle.setDisputeWindow(1 hours);
    oracle.setDisputeBondMultiplier(150);
    oracle.setDisputeBondAmount(0.2 ether);
    vm.stopPrank();

    // Create request (selects 2 agents)
    uint256 requestId = _createStakedRequest(2);
    address[] memory selected = oracle.getSelectedAgents(requestId);
    assertEq(selected.length, 2);

    // Both commit (no bond needed)
    bytes memory a1 = abi.encode("sunny, 27C");
    bytes memory a2 = abi.encode("partly cloudy, 26C");
    vm.prank(selected[0]);
    oracle.commit(requestId, keccak256(abi.encode(a1, uint256(111))));
    vm.prank(selected[1]);
    oracle.commit(requestId, keccak256(abi.encode(a2, uint256(222))));

    // Both reveal
    vm.prank(selected[0]);
    oracle.reveal(requestId, a1, 111);
    vm.prank(selected[1]);
    oracle.reveal(requestId, a2, 222);

    // Judge aggregates (picks selected[0] as winner)
    address judgeAddr = oracle.selectedJudge(requestId);
    address[] memory winners = new address[](1);
    winners[0] = selected[0];
    vm.prank(judgeAddr);
    oracle.aggregate(requestId, a1, winners, abi.encode("more accurate"));

    // Dispute window passes
    vm.warp(block.timestamp + 1 hours + 1);

    // Distribute
    uint256 winnerBalBefore = selected[0].balance;
    oracle.distributeRewards(requestId);

    // Winner gets reward + loser's slashed stake
    uint256 expectedSlash = MIN_STAKE * SLASH_PCT / 10000;
    assertEq(selected[0].balance, winnerBalBefore + REWARD + expectedSlash);

    // Verify stakes
    (uint256 winnerStake,,,) = oracle.agentStakes(selected[0]);
    assertEq(winnerStake, MIN_STAKE); // untouched

    (uint256 loserStake,,,) = oracle.agentStakes(selected[1]);
    assertEq(loserStake, MIN_STAKE - expectedSlash); // slashed

    // Active assignments cleared
    assertEq(oracle.activeAssignments(selected[0]), 0);
    assertEq(oracle.activeAssignments(selected[1]), 0);

    // Phase is distributed
    assertEq(uint8(oracle.phases(requestId)), uint8(NousOracle.Phase.Distributed));
}
```

- [ ] **Step 2: Run E2E test**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test --match-test test_fullFlow_stakingModel -vvv`
Expected: PASS

- [ ] **Step 3: Run full test suite to verify no regressions**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 4: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add test/NousOracle.t.sol
git commit -m "test: add full E2E staking flow test"
```

---

### Task 9: Update Upgrade Script

**Files:**
- Modify: `script/Upgrade.s.sol`

- [ ] **Step 1: Update Upgrade.s.sol to configure staking parameters**

Add staking config after the existing dispute config in the `run()` function:

```solidity
// 5. Configure staking parameters
uint256 minStake = vm.envOr("MIN_STAKE_AMOUNT", uint256(0.5 ether));
uint256 slashPct = vm.envOr("SLASH_PERCENTAGE", uint256(5000));
uint256 withdrawCooldown = vm.envOr("WITHDRAWAL_COOLDOWN", uint256(1 days));
uint256 flatDisputeBond = vm.envOr("DISPUTE_BOND_AMOUNT", uint256(0.2 ether));

proxy.setMinStakeAmount(minStake);
console.log("Min stake amount set:", minStake);

proxy.setSlashPercentage(slashPct);
console.log("Slash percentage set:", slashPct);

proxy.setWithdrawalCooldown(withdrawCooldown);
console.log("Withdrawal cooldown set:", withdrawCooldown);

proxy.setDisputeBondAmount(flatDisputeBond);
console.log("Dispute bond amount set:", flatDisputeBond);
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge build`
Expected: Compiles successfully

- [ ] **Step 3: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add script/Upgrade.s.sol
git commit -m "feat: add staking parameters to upgrade script"
```

---

### Task 10: Update Client ABI and Types

**Files:**
- Modify: `client/src/oracleAbi.ts`
- Modify: `client/src/types.ts`

- [ ] **Step 1: Add staking ABI entries to oracleAbi.ts**

Add the following entries to the `oracleAbi` array in `client/src/oracleAbi.ts`:

```typescript
// Staking functions
{
  type: 'function',
  name: 'registerAgent',
  stateMutability: 'payable',
  inputs: [{ name: 'role', type: 'uint8' }],
  outputs: [],
},
{
  type: 'function',
  name: 'addStake',
  stateMutability: 'payable',
  inputs: [{ name: 'amount', type: 'uint256' }],
  outputs: [],
},
{
  type: 'function',
  name: 'requestWithdrawal',
  stateMutability: 'nonpayable',
  inputs: [],
  outputs: [],
},
{
  type: 'function',
  name: 'executeWithdrawal',
  stateMutability: 'nonpayable',
  inputs: [],
  outputs: [],
},
{
  type: 'function',
  name: 'cancelWithdrawal',
  stateMutability: 'nonpayable',
  inputs: [],
  outputs: [],
},
{
  type: 'function',
  name: 'agentStakes',
  stateMutability: 'view',
  inputs: [{ name: 'agent', type: 'address' }],
  outputs: [
    { name: 'amount', type: 'uint256' },
    { name: 'role', type: 'uint8' },
    { name: 'registered', type: 'bool' },
    { name: 'withdrawRequestTime', type: 'uint256' },
  ],
},
{
  type: 'function',
  name: 'activeAssignments',
  stateMutability: 'view',
  inputs: [{ name: 'agent', type: 'address' }],
  outputs: [{ name: '', type: 'uint256' }],
},
{
  type: 'function',
  name: 'getSelectedAgents',
  stateMutability: 'view',
  inputs: [{ name: 'requestId', type: 'uint256' }],
  outputs: [{ name: '', type: 'address[]' }],
},
{
  type: 'function',
  name: 'getRegisteredInfoAgents',
  stateMutability: 'view',
  inputs: [],
  outputs: [{ name: '', type: 'address[]' }],
},
{
  type: 'function',
  name: 'getRegisteredJudges',
  stateMutability: 'view',
  inputs: [],
  outputs: [{ name: '', type: 'address[]' }],
},
{
  type: 'function',
  name: 'minStakeAmount',
  stateMutability: 'view',
  inputs: [],
  outputs: [{ name: '', type: 'uint256' }],
},
```

- [ ] **Step 2: Add staking types to types.ts**

Add to `client/src/types.ts`:

```typescript
export type AgentRole = 'info' | 'judge';

export interface AgentStakeInfo {
  address: Address;
  amount: bigint;
  role: AgentRole;
  registered: boolean;
  withdrawRequestTime: bigint;
  activeAssignments: bigint;
}
```

Add `selectedAgents` to `RequestContext`:

```typescript
export interface RequestContext {
  requestId: bigint;
  phase: PhaseName;
  request: OracleRequest;
  committedAgents: Address[];
  commitHashes: Hex[];
  revealedAgents: Address[];
  revealedAnswers: Hex[];
  selectedJudge: Address;
  revealDeadline: bigint;
  finalized: boolean;
  finalAnswer: Hex;
  selectedAgents: Address[]; // NEW: agents selected for this request
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add client/src/oracleAbi.ts client/src/types.ts
git commit -m "feat: add staking ABI entries and types"
```

---

### Task 11: Update Chain Client

**Files:**
- Modify: `client/src/chain.ts`

- [ ] **Step 1: Add staking functions to NousChainClient interface**

Add to the `NousChainClient` interface in `client/src/chain.ts` (after line 80):

```typescript
registerAgent(agentAddress: Address, role: 'info' | 'judge'): Promise<Hex>;
addStake(agentAddress: Address, amount: bigint): Promise<Hex>;
requestWithdrawal(agentAddress: Address): Promise<Hex>;
executeWithdrawal(agentAddress: Address): Promise<Hex>;
getAgentStake(agentAddress: Address): Promise<{ amount: bigint; role: number; registered: boolean; withdrawRequestTime: bigint }>;
getSelectedAgents(requestId: bigint): Promise<Address[]>;
getRegisteredInfoAgents(): Promise<Address[]>;
getRegisteredJudges(): Promise<Address[]>;
getMinStakeAmount(): Promise<bigint>;
```

- [ ] **Step 2: Update getRequestContext to include selectedAgents**

In the `getRequestContext` function, add `getSelectedAgents` to the parallel reads:

```typescript
async function getRequestContext(requestId: bigint): Promise<RequestContext> {
  const [phaseIndex, request, commits, reveals, selectedJudge, revealDeadline, resolution, selectedAgents] =
    await Promise.all([
      // ... existing reads ...
      publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'getSelectedAgents',
        args: [requestId],
      }),
    ]);

  // ... existing code ...

  return {
    // ... existing fields ...
    selectedAgents: (selectedAgents as Address[]).map((a) => getAddress(a)),
  };
}
```

- [ ] **Step 3: Implement staking functions in createNousChainClient**

Add to the returned object in `createNousChainClient()`:

```typescript
async registerAgent(agentAddress: Address, role: 'info' | 'judge') {
  const walletClient = getWalletClient(agentAddress);
  const minStake = (await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'minStakeAmount',
  })) as bigint;

  const roleEnum = role === 'info' ? 0 : 1;
  const hash = await withRetry(() => walletClient.writeContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'registerAgent',
    args: [roleEnum],
    chain: walletClient.chain,
    account: walletClient.account!,
    gas: DEFAULT_GAS,
    value: minStake,
  }));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === 'reverted') throw new Error(`registerAgent tx ${hash} reverted`);
  return hash;
},
async addStake(agentAddress: Address, amount: bigint) {
  const walletClient = getWalletClient(agentAddress);
  const hash = await withRetry(() => walletClient.writeContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'addStake',
    args: [0n], // ETH mode: amount from msg.value
    chain: walletClient.chain,
    account: walletClient.account!,
    gas: DEFAULT_GAS,
    value: amount,
  }));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === 'reverted') throw new Error(`addStake tx ${hash} reverted`);
  return hash;
},
async requestWithdrawal(agentAddress: Address) {
  const walletClient = getWalletClient(agentAddress);
  const hash = await withRetry(() => walletClient.writeContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'requestWithdrawal',
    args: [],
    chain: walletClient.chain,
    account: walletClient.account!,
    gas: DEFAULT_GAS,
  }));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === 'reverted') throw new Error(`requestWithdrawal tx ${hash} reverted`);
  return hash;
},
async executeWithdrawal(agentAddress: Address) {
  const walletClient = getWalletClient(agentAddress);
  const hash = await withRetry(() => walletClient.writeContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'executeWithdrawal',
    args: [],
    chain: walletClient.chain,
    account: walletClient.account!,
    gas: DEFAULT_GAS,
  }));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === 'reverted') throw new Error(`executeWithdrawal tx ${hash} reverted`);
  return hash;
},
async getAgentStake(agentAddress: Address) {
  const result = await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'agentStakes',
    args: [agentAddress],
  });
  const [amount, role, registered, withdrawRequestTime] = result as [bigint, number, boolean, bigint];
  return { amount, role, registered, withdrawRequestTime };
},
async getSelectedAgents(requestId: bigint) {
  const result = await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'getSelectedAgents',
    args: [requestId],
  });
  return (result as Address[]).map((a) => getAddress(a));
},
async getRegisteredInfoAgents() {
  const result = await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'getRegisteredInfoAgents',
  });
  return (result as Address[]).map((a) => getAddress(a));
},
async getRegisteredJudges() {
  const result = await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'getRegisteredJudges',
  });
  return (result as Address[]).map((a) => getAddress(a));
},
async getMinStakeAmount() {
  return (await publicClient.readContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'minStakeAmount',
  })) as bigint;
},
```

- [ ] **Step 4: Remove bond logic from commit()**

In the `commit` function of `createNousChainClient()`, remove the ERC-20 bond approval block and the `value` property (agents no longer need to send bonds for staking-model requests):

```typescript
async commit(agentAddress, requestId, commitment) {
  const request = await getRequest(requestId);
  const walletClient = getWalletClient(agentAddress);
  const isStakingModel = request.bondAmount === 0n;

  if (!isStakingModel && request.bondToken !== zeroAddress && request.bondAmount > 0n) {
    // Legacy bond model: approve ERC-20
    const currentAllowance = await publicClient.readContract({
      address: request.bondToken,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [agentAddress, oracleAddress],
    });
    if (currentAllowance < request.bondAmount) {
      console.log(`[chain] Approving ${request.bondAmount} bond tokens for ${agentAddress}...`);
      const approveHash = await walletClient.writeContract({
        address: request.bondToken,
        abi: erc20Abi,
        functionName: 'approve',
        args: [oracleAddress, request.bondAmount * 10n],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      });
      const approveReceipt = await publicClient.waitForTransactionReceipt({ hash: approveHash });
      if (approveReceipt.status === 'reverted') throw new Error(`approve tx ${approveHash} reverted`);
      console.log(`[chain] Bond token approved: ${approveHash}`);
    }
  }

  const hash = await withRetry(() => walletClient.writeContract({
    address: oracleAddress,
    abi: oracleAbi,
    functionName: 'commit',
    args: [requestId, commitment],
    chain: walletClient.chain,
    account: walletClient.account!,
    gas: DEFAULT_GAS,
    value: (!isStakingModel && request.bondToken === zeroAddress) ? request.bondAmount : undefined,
  }));
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === 'reverted') throw new Error(`commit tx ${hash} reverted`);
  return hash;
},
```

- [ ] **Step 5: Verify TypeScript compiles**

Run: `cd /Users/davidcai/taiko/hackathon/nous/client && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add client/src/chain.ts
git commit -m "feat: add staking functions to chain client"
```

---

### Task 12: Update Worker for Staking Model

**Files:**
- Modify: `client/src/worker.ts`

- [ ] **Step 1: Add registration check on startup**

In `createWorker()`, modify the `startup()` function to check agent registration. Add at the beginning of `startup()`:

```typescript
async startup() {
  logger.info('[startup] Checking agent registration...');

  for (const agent of infoAgents) {
    const stake = await chain.getAgentStake(agent.address);
    if (!stake.registered) {
      logger.info(`[startup] Agent ${agent.address} not registered, registering as info agent...`);
      try {
        const hash = await chain.registerAgent(agent.address, 'info');
        logger.info(`[startup] Agent ${agent.address} registered: ${hash}`);
      } catch (err) {
        logger.error(`[startup] Failed to register ${agent.address}: ${err instanceof Error ? err.message : String(err)}`);
      }
    } else {
      logger.info(`[startup] Agent ${agent.address} already registered (stake=${stake.amount})`);
    }
  }

  for (const judge of judgeAgents) {
    const stake = await chain.getAgentStake(judge.address);
    if (!stake.registered) {
      logger.info(`[startup] Judge ${judge.address} not registered, registering as judge...`);
      try {
        const hash = await chain.registerAgent(judge.address, 'judge');
        logger.info(`[startup] Judge ${judge.address} registered: ${hash}`);
      } catch (err) {
        logger.error(`[startup] Failed to register ${judge.address}: ${err instanceof Error ? err.message : String(err)}`);
      }
    } else {
      logger.info(`[startup] Judge ${judge.address} already registered (stake=${stake.amount})`);
    }
  }

  // ... rest of existing startup logic ...
```

- [ ] **Step 2: Modify handleCommitting to check selection**

In `handleCommitting()`, change the logic to only commit to requests where the agent is in `selectedAgents`:

```typescript
async function handleCommitting(context: RequestContext): Promise<void> {
  const committed = new Set(context.committedAgents.map(lower));
  const isStakingModel = context.request.bondAmount === 0n;
  let remainingSlots = Number(context.request.numInfoAgents - BigInt(context.committedAgents.length));
  logger.info(`[req=${context.requestId}] Committing: ${context.committedAgents.length}/${context.request.numInfoAgents} agents committed, ${remainingSlots} slots remaining`);

  // In staking model, only selected agents can commit
  const selectedSet = isStakingModel
    ? new Set(context.selectedAgents.map(lower))
    : null;

  for (const agent of infoAgents) {
    if (remainingSlots <= 0) {
      logger.info(`[req=${context.requestId}] All slots filled, skipping ${agent.address}`);
      break;
    }
    if (committed.has(lower(agent.address))) {
      logger.info(`[req=${context.requestId}] Agent ${agent.address} already committed, skipping`);
      continue;
    }
    if (selectedSet && !selectedSet.has(lower(agent.address))) {
      logger.info(`[req=${context.requestId}] Agent ${agent.address} not selected for this request, skipping`);
      continue;
    }

    // ... rest of existing commit logic (generate, upload, commit) unchanged ...
```

- [ ] **Step 3: Verify TypeScript compiles**

Run: `cd /Users/davidcai/taiko/hackathon/nous/client && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add client/src/worker.ts
git commit -m "feat: worker checks registration on startup, respects selection"
```

---

### Task 13: Update Frontend

**Files:**
- Modify: `web/index.html`

- [ ] **Step 1: Add Agent Registry panel**

In `web/index.html`, find the Agent Council section and add a "Stake" column. Add after the existing agent card rendering logic a display of each agent's stake amount. The changes are:

1. Add a `getAgentStake(address)` call in the JS section to read stakes.
2. In the agent card template, display the stake amount below the role badge.
3. In each request card, show selected agents (from `getSelectedAgents(requestId)`).
4. Remove the bond amount from the "Create Request" modal form.

The exact HTML/JS changes depend heavily on the existing template structure. Key additions:

**In the JavaScript section that fetches agent data, add:**

```javascript
async function getAgentStake(address) {
  try {
    const result = await publicClient.readContract({
      address: ORACLE_ADDRESS,
      abi: oracleAbi,
      functionName: 'agentStakes',
      args: [address],
    });
    return { amount: result[0], role: result[1], registered: result[2], withdrawRequestTime: result[3] };
  } catch {
    return null;
  }
}

async function getSelectedAgents(requestId) {
  try {
    return await publicClient.readContract({
      address: ORACLE_ADDRESS,
      abi: oracleAbi,
      functionName: 'getSelectedAgents',
      args: [requestId],
    });
  } catch {
    return [];
  }
}
```

**In the agent card HTML template, add after the role badge:**

```html
<div class="agent-stake" style="font-size: 0.75rem; color: #aaa; margin-top: 4px;">
  Stake: ${stakeInfo ? formatEther(stakeInfo.amount) + ' ETH' : 'N/A'}
</div>
```

**In the request card metadata grid, replace the Bond row:**

```html
<!-- Before (remove): -->
<div class="meta-item"><span class="meta-label">Bond</span><span>${formatEther(req.bondAmount)} ETH</span></div>

<!-- After (add): -->
<div class="meta-item"><span class="meta-label">Selected</span><span>${selectedAgents.length} agents</span></div>
```

**In the Create Request modal, remove the bond amount input field.**

- [ ] **Step 2: Add ABI entries to frontend**

Add the new ABI entries (`agentStakes`, `getSelectedAgents`, `getRegisteredInfoAgents`, `getRegisteredJudges`, `registerAgent`) to the inline ABI array in `web/index.html`.

- [ ] **Step 3: Test in browser**

Open `web/index.html` in a browser and verify:
- Agent cards show stake amounts
- Request cards show selected agents instead of bond amount
- Create Request form no longer has bond fields

- [ ] **Step 4: Commit**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add web/index.html
git commit -m "feat: update frontend for staking model"
```

---

### Task 14: Final Verification

**Files:** All modified files

- [ ] **Step 1: Run full Solidity test suite**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge test -vvv`
Expected: ALL PASS

- [ ] **Step 2: Run TypeScript compilation check**

Run: `cd /Users/davidcai/taiko/hackathon/nous/client && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Verify forge build succeeds**

Run: `cd /Users/davidcai/taiko/hackathon/nous && forge build`
Expected: Successful compilation with no warnings

- [ ] **Step 4: Final commit if any cleanup needed**

```bash
cd /Users/davidcai/taiko/hackathon/nous
git add -A
git status
# Only commit if there are changes
git commit -m "chore: final cleanup for upfront agent staking"
```
