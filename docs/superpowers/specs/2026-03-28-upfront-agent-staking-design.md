# Upfront Agent Staking Design

## Overview

Replace the current per-request bond model with a global upfront staking mechanism. Agents must stake tokens to register in the protocol before they can be selected for and answer requests. This also replaces the owner-managed judge whitelist with a unified permissionless staking system for both info agents and judges.

## Goals

- Agents commit economic skin-in-the-game before participating
- Permissionless registration for both info agents and judges (no owner whitelist)
- Random agent selection from the registered pool per request
- Simplify the per-request flow by removing bond transfers at commit time

## Design Decisions

| Decision | Choice |
|----------|--------|
| Stake model | Global registration (not per-request) |
| Selection method | Random from registered pool |
| Per-request bond | Removed — global stake is sole collateral |
| Slash model | Proportional — deduct % from stake, auto-deregister below minimum |
| Parameters | Owner-configurable |
| Role model | Unified staking for info agents and judges |
| Withdrawal | Cooldown period before funds released |

---

## Section 1: Agent Registration & Staking

### New Storage

```solidity
enum AgentRole { Info, Judge }

struct AgentStake {
    uint256 amount;              // current stake balance
    AgentRole role;              // Info or Judge
    bool registered;             // active in pool
    uint256 withdrawRequestTime; // 0 = no pending withdrawal
}

mapping(address => AgentStake) public agentStakes;
address[] internal _registeredInfoAgents;
address[] internal _registeredJudges;

// Owner-configurable parameters
uint256 public minStakeAmount;
uint256 public slashPercentage;       // basis points (e.g., 5000 = 50%)
uint256 public withdrawalCooldown;    // seconds
```

### Registration Flow

1. Agent calls `registerAgent(AgentRole role)` with `msg.value >= minStakeAmount` (ETH) or ERC-20 transfer
2. Contract stores stake, adds agent to the appropriate role pool (`_registeredInfoAgents` or `_registeredJudges`)
3. Agent is now eligible for random selection

### Top-Up

Agents can call `addStake()` to increase their stake at any time (useful after partial slashing to stay above minimum).

### Rules

- One role per address. An operator wanting to be both info and judge uses two addresses.
- Cannot register if already registered.
- Registration stake token matches a contract-level `stakeToken` parameter (set at initialization — either `address(0)` for ETH or an ERC-20 address).

---

## Section 2: Agent Selection for Requests

### Selection Mechanism

When a request is created via `createRequest()`, the contract immediately selects `numInfoAgents` from `_registeredInfoAgents` using pseudo-random selection:

```
seed = keccak256(blockhash(block.number - 1), requestId, i)
selectedIndex = seed % registeredInfoAgents.length
```

### New Storage

```solidity
mapping(uint256 => address[]) public selectedAgents;  // requestId → selected info agents
mapping(address => uint256) public activeAssignments;  // agent → count of active requests
```

### Flow

1. Requester calls `createRequest()` — same parameters as today minus `bondAmount` and `bondToken`
2. Contract selects N agents randomly from `_registeredInfoAgents`
3. Selected agents are stored in `selectedAgents[requestId]`
4. Each selected agent's `activeAssignments` counter increments
5. Phase transitions to `Committing` — only selected agents can call `commit()`

### Changes to `commit()`

- No longer accepts `msg.value` or transfers bond tokens
- Instead checks: `require(isSelectedForRequest(msg.sender, requestId))`
- Still accepts the `bytes32 commitment` (commit-reveal unchanged)

### Non-Committing Selected Agents

When the commit deadline passes, move forward with whoever committed. Non-committing selected agents get slashed (assigned but didn't show up).

### Insufficient Registered Agents

If `numInfoAgents` exceeds the number of registered info agents, `createRequest()` reverts. Requester must reduce `numInfoAgents` or wait for more agents to register.

### Judge Selection

Stays lazy — happens at transition to Judging phase (like today), but selects from `_registeredJudges` instead of the owner whitelist.

---

## Section 3: Slashing & Reward Distribution

### Slashable Offenses

| Offense | When Detected | Slash |
|---------|--------------|-------|
| Selected but didn't commit | Commit deadline passes | `slashPercentage` of stake |
| Committed but didn't reveal | Reveal deadline passes | `slashPercentage` of stake |
| Revealed but lost judging | `aggregate()` called | `slashPercentage` of stake |

### Slashing Mechanics

1. Slash amount = `agentStakes[agent].amount * slashPercentage / 10000`
2. Deduct from `agentStakes[agent].amount`
3. If remaining stake < `minStakeAmount` → set `registered = false`, remove from selection pool (no longer eligible for new requests). `activeAssignments` is NOT decremented here — it only decrements when the request resolves via `distributeRewards()`
4. Slashed funds accumulate in the request's reward pool

### Reward Distribution

`distributeRewards()` distributes:
- Original `rewardAmount` from requester (unchanged)
- Accumulated slashed funds from that request's losers/no-shows

Per-winner share = `(rewardAmount + totalSlashed) / numWinners`

Winners' stakes are untouched — they keep their full global stake and receive rewards on top.

All slashed funds go to winners (requester no longer receives a share of slashed bonds).

---

## Section 4: Withdrawal & Cooldown

### Withdrawal Flow

1. Agent calls `requestWithdrawal()` — sets `withdrawRequestTime = block.timestamp`
2. Agent is immediately removed from the selection pool (`registered = false`, removed from role array)
3. After `withdrawalCooldown` seconds pass, agent calls `executeWithdrawal()` — transfers stake back
4. If agent has `activeAssignments > 0`, `requestWithdrawal()` reverts — must wait for all active requests to resolve first

### Cancellation

Agent can call `cancelWithdrawal()` to re-enter the pool if cooldown hasn't elapsed yet and stake still meets minimum.

### Rationale for Immediate Pool Removal

Prevents an agent from being selected for new requests during cooldown while planning to leave. They still must fulfill any existing assignments.

### Configuration

`withdrawalCooldown` is set by owner, updatable via `setWithdrawalCooldown(uint256 seconds)`.

---

## Section 5: Owner Configuration & Migration

### New Owner Functions

```solidity
setMinStakeAmount(uint256 amount)
setSlashPercentage(uint256 basisPoints)    // max 10000
setWithdrawalCooldown(uint256 seconds)
setStakeToken(address token)               // only before any agents register
```

### Removed Functions

- `addJudge()` / `removeJudge()` — replaced by `registerAgent(Judge)`
- `bondAmount` and `bondToken` removed from `Request` struct and `createRequest()` parameters

### Migration Path (UUPS Upgrade)

1. Deploy new implementation with staking logic
2. Call `upgradeToAndCall()` with an initializer that:
   - Sets default `minStakeAmount`, `slashPercentage`, `withdrawalCooldown`
   - Migrates existing whitelisted judges: for each address in `_judgeList`, auto-register them with zero stake (grandfathered) or require them to stake post-upgrade
3. Existing in-flight requests continue under old rules (bond-based) — new requests use staking
4. Once all old requests resolve, legacy bond storage is dead weight but harmless

### Dispute Bond Changes

The current dispute bond is calculated as `bondAmount * disputeBondMultiplier / 100`. Since `bondAmount` is removed from new requests, dispute bonds for post-upgrade requests use a new flat `disputeBondAmount` parameter (owner-configurable, stored alongside other staking parameters). Pre-upgrade in-flight requests continue using the old `bondAmount`-based calculation.

### Backward Compatibility for In-Flight Requests

`commit()` checks: if request was created pre-upgrade (has `bondAmount > 0`), use old bond logic. If post-upgrade (no bond), use staking/selection logic.

---

## Section 6: Client & Frontend Changes

### Client (`client/src/worker.ts`)

- New startup step: check if agent is registered. If not, call `registerAgent(role)` with stake (or log error and exit).
- `handleCommitting()`: only commit to requests where the agent appears in `selectedAgents[requestId]`. Remove bond transfer from commit call.
- New polling: watch for `AgentSelected` events or check `selectedAgents` to know when assigned.

### Chain Client (`client/src/chain.ts`)

New functions:
- `registerAgent(role, stakeAmount)`
- `addStake(amount)`
- `requestWithdrawal()`
- `executeWithdrawal()`
- `getAgentStake(address)` — read stake info
- `getSelectedAgents(requestId)` — read who's assigned

Remove bond-related logic from `commit()`.

### Frontend (`web/index.html`)

- Agent Council section: show each agent's stake amount and role
- New "Agent Registry" panel: list all registered agents with stakes, role, status
- Request cards: show selected agents per request
- Remove bond amount from request creation form
- Add agent registration UI (for manual registration if needed)

### Unchanged

- `infoAgent.ts` / `judgeAgent.ts` — LLM logic unchanged
- `ipfs.ts` — content storage unchanged
- Commit-reveal cryptography — unchanged
- Dispute and DAO escalation flows — unchanged (slashing draws from global stake instead of per-request bond)
