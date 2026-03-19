# Dispute Resolution & DAO Escalation Extension

**Date:** 2026-03-19
**Status:** Draft
**ERC Reference:** [EIP-8033 Optional Dispute Resolution Extension](https://eips.ethereum.org/EIPS/eip-8033)

## Overview

Adds a two-tier post-finalization challenge mechanism to NousOracle: a single automated dispute (re-judged by a different judge) followed by an optional DAO escalation as the final backstop. Implemented inline in `NousOracle.sol` (Approach 3) with clear internal separation, leveraging the existing UUPS upgrade path.

## Design Decisions

| Decision | Choice |
|---|---|
| Who can dispute | Anyone (permissionless) |
| Dispute judge selection | Random from existing pool, excluding the original judge |
| Dispute bond | Global multiplier on original bond (default 1.5x), owner-configurable |
| Dispute window | Owner-configurable duration (default 1 hour) |
| Phase model | Explicit new phases: `DisputeWindow`, `Disputed`, `DAOEscalation` |
| Dispute rounds | Single dispute only |
| DAO escalation | After dispute resolution, second window to escalate to DAO address |
| DAO escalation bond | Flat owner-configurable amount, always in Taiko ERC-20 |
| DAO address | Simple `address` set by owner, contract-agnostic |
| Forfeited bond split | 50% to winners, 50% to requester |

## Phase State Machine

### Updated Enum

New phases are **appended** after the existing enum values to preserve UUPS storage compatibility. Existing requests stored as `Distributed` (5) or `Failed` (6) retain their correct meaning.

```solidity
enum Phase {
    None,           // 0  (unchanged)
    Committing,     // 1  (unchanged)
    Revealing,      // 2  (unchanged)
    Judging,        // 3  (unchanged)
    Finalized,      // 4  (unchanged, no longer entered in normal flow post-upgrade)
    Distributed,    // 5  (unchanged)
    Failed,         // 6  (unchanged)
    DisputeWindow,  // 7  (new)
    Disputed,       // 8  (new)
    DAOEscalation   // 9  (new)
}
```

### Transitions

```
Judging ──(aggregate)──→ DisputeWindow ──(window expires, no dispute)──→ Distributed
                              │
                              ├──(dispute filed)──→ Disputed
                              │                        │
                              │                   (judge resolves)
                              │                        │
                              │                   DisputeWindow ──(window expires, no escalation)──→ Distributed
                              │                        │
                              │                   (DAO escalation filed)
                              │                        │
                              │                   DAOEscalation ──(DAO rules or timeout)──→ Distributed
```

- `aggregate()` transitions to `DisputeWindow` (not `Finalized`)
- `distributeRewards()` requires `DisputeWindow` phase with expired window
- The `DisputeWindow` phase serves dual purpose:
  - **First window** (after `aggregate`): `disputeUsed == false` → dispute or DAO escalation not yet available, only `initiateDispute` or let expire
  - **Second window** (after `resolveDispute`): `disputeUsed == true` → only `initiateDAOEscalation` or let expire
- After DAO resolution or timeout, `disputeWindowEnd` is set to `block.timestamp` (immediately expired) so distribution is available

## New Storage

### Owner-Configurable Parameters

```solidity
uint256 public disputeWindow;              // duration in seconds (default 1 hour)
uint256 public disputeBondMultiplier;       // e.g., 150 = 1.5x original bond, minimum 100
uint256 public daoEscalationBond;           // flat amount in Taiko ERC-20
address public daoEscalationBondToken;      // Taiko ERC-20 token address (must be non-zero)
address public daoAddress;                  // address authorized to resolve DAO escalations
uint256 public daoResolutionWindow;         // max time for DAO to act (default 7 days)
```

### Per-Request Dispute State

```solidity
mapping(uint256 => uint256) public disputeWindowEnd;
mapping(uint256 => bool) public disputeUsed;
mapping(uint256 => address) public disputer;
mapping(uint256 => uint256) public disputeBondPaid;
mapping(uint256 => string) public disputeReason;
mapping(uint256 => address) public disputeJudge;
mapping(uint256 => bool) public daoEscalationUsed;
mapping(uint256 => address) public daoEscalator;
mapping(uint256 => uint256) public daoEscalationBondPaid;
mapping(uint256 => uint256) public daoEscalationDeadline;
```

### Setter Functions (Owner-Only)

```solidity
function setDisputeWindow(uint256 duration) external onlyOwner;
function setDisputeBondMultiplier(uint256 multiplier) external onlyOwner;  // requires multiplier >= 100
function setDaoEscalationBond(uint256 amount) external onlyOwner;
function setDaoEscalationBondToken(address token) external onlyOwner;     // requires token != address(0)
function setDaoAddress(address dao) external onlyOwner;
function setDaoResolutionWindow(uint256 duration) external onlyOwner;
```

All setters emit corresponding parameter-change events (see Events section).

Storage is appended after existing variables — no collision risk with the UUPS proxy.

## Events

```solidity
// Dispute lifecycle events
event DisputeInitiated(uint256 indexed requestId, address disputer, string reason);
event DisputeWindowOpened(uint256 indexed requestId, uint256 endTimestamp);
event DisputeResolved(uint256 indexed requestId, bool overturned, bytes finalAnswer);
event DAOEscalationInitiated(uint256 indexed requestId, address escalator);
event DAOEscalationResolved(uint256 indexed requestId, bytes finalAnswer);
event DAOEscalationTimedOut(uint256 indexed requestId);

// Parameter change events
event DisputeWindowUpdated(uint256 oldDuration, uint256 newDuration);
event DisputeBondMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
event DaoEscalationBondUpdated(uint256 oldAmount, uint256 newAmount);
event DaoEscalationBondTokenUpdated(address oldToken, address newToken);
event DaoAddressUpdated(address oldDao, address newDao);
event DaoResolutionWindowUpdated(uint256 oldDuration, uint256 newDuration);
```

## Errors

```solidity
error DisputeWindowNotOpen(uint256 requestId);
error DisputeWindowNotExpired(uint256 requestId);
error DisputeAlreadyUsed(uint256 requestId);
error InsufficientDisputeBond(uint256 required, uint256 provided);
error NotDisputeJudge(uint256 requestId, address caller);
error NoDisputeJudgeAvailable(uint256 requestId);
error DAOEscalationAlreadyUsed(uint256 requestId);
error DAONotSet();
error NotDAO(address caller);
error InsufficientDAOEscalationBond(uint256 required, uint256 provided);
error NotInDisputedPhase(uint256 requestId);
error NotInDAOEscalation(uint256 requestId);
error DAOResolutionTimedOut(uint256 requestId);
error DisputeBondMultiplierTooLow(uint256 multiplier);
error InvalidBondTokenAddress();
error ETHSentWithERC20Bond();
```

## Functions

### `initiateDispute(uint256 requestId, string calldata reason) external payable`

**Guards:**
- Phase is `DisputeWindow`
- `block.timestamp < disputeWindowEnd[requestId]`
- `disputeUsed[requestId]` is false

**Bond:**
- Required: `request.bondAmount * disputeBondMultiplier / 100`
- Paid in `request.bondToken` (ETH via msg.value, or ERC-20 via transferFrom)
- If `request.bondToken != address(0)` (ERC-20): require `msg.value == 0` to prevent ETH getting stuck

**Effects:**
1. Store `disputer`, `disputeBondPaid`, `disputeReason`
2. Set `disputeUsed = true`
3. Select dispute judge: random from judge pool excluding `selectedJudge[requestId]`. Revert with `NoDisputeJudgeAvailable` if no other judge exists.
4. Transition to `Disputed` phase
5. Emit `DisputeInitiated`

### `resolveDispute(uint256 requestId, bool overturn, bytes calldata newAnswer, address[] calldata newWinners) external`

**Guards:**
- Phase is `Disputed`
- `msg.sender == disputeJudge[requestId]`
- If `overturn`: `newWinners` non-empty, all must have revealed

**If upheld** (`overturn = false`):
- Disputer's bond forfeited: 50% split equally to original winners, 50% to requester
- `_finalAnswers`, `_winners` unchanged

**If overturned** (`overturn = true`):
- Disputer's bond returned in full
- `_finalAnswers[requestId]` and `_winners[requestId]` updated to new values

**In both cases:**
- Transition to `DisputeWindow`
- Set `disputeWindowEnd = block.timestamp + disputeWindow`
- Emit `DisputeResolved` and `DisputeWindowOpened`

### `initiateDAOEscalation(uint256 requestId) external`

Note: **not** `payable` — DAO escalation bond is always ERC-20, so no ETH should be sent.

**Guards:**
- Phase is `DisputeWindow`
- `block.timestamp < disputeWindowEnd[requestId]`
- `disputeUsed[requestId]` is true (dispute already happened)
- `daoEscalationUsed[requestId]` is false
- `daoAddress != address(0)`

**Bond:**
- Required: `daoEscalationBond` (flat amount)
- Paid in `daoEscalationBondToken` (Taiko ERC-20, always via transferFrom)

**Effects:**
1. Store `daoEscalator`, `daoEscalationBondPaid`
2. Set `daoEscalationUsed = true`
3. Set `daoEscalationDeadline = block.timestamp + daoResolutionWindow`
4. Transition to `DAOEscalation` phase
5. Emit `DAOEscalationInitiated`

### `resolveDAOEscalation(uint256 requestId, bool overturn, bytes calldata newAnswer, address[] calldata newWinners) external`

**Guards:**
- Phase is `DAOEscalation`
- `msg.sender == daoAddress`
- `block.timestamp <= daoEscalationDeadline[requestId]` (DAO hasn't timed out)
- If `overturn`: `newWinners` non-empty, all must have revealed

**If upheld** (`overturn = false`):
- Escalator's bond forfeited: 50% split equally to winners, 50% to requester (paid in Taiko ERC-20)

**If overturned** (`overturn = true`):
- Escalator's bond returned in full (Taiko ERC-20)
- `_finalAnswers[requestId]` and `_winners[requestId]` updated

**In both cases:**
- Transition to `DisputeWindow` with `disputeWindowEnd = block.timestamp` (immediately expired, DAO is final)
- Emit `DAOEscalationResolved`

### `timeoutDAOEscalation(uint256 requestId) external`

Called by anyone if the DAO fails to act within `daoResolutionWindow`.

**Guards:**
- Phase is `DAOEscalation`
- `block.timestamp > daoEscalationDeadline[requestId]`

**Effects:**
- Escalator's bond returned in full (DAO failed to act, not escalator's fault)
- Current `_finalAnswers` and `_winners` stand (dispute judge's decision holds)
- Transition to `DisputeWindow` with `disputeWindowEnd = block.timestamp` (immediately expired)
- Emit `DAOEscalationTimedOut`

### Modified `aggregate()`

- After storing final answer/winners/reasoning, transitions to `DisputeWindow` (not `Finalized`)
- Sets `disputeWindowEnd = block.timestamp + disputeWindow`
- Emits `DisputeWindowOpened`

### Modified `distributeRewards()`

- Guard changes: requires `DisputeWindow` phase AND `block.timestamp >= disputeWindowEnd[requestId]`
- Reward calculation logic unchanged — reads from `_winners` (which may have been updated by dispute/DAO)
- Transitions to `Distributed`

## Bond Token Handling

| Bond | Token | Mechanism |
|---|---|---|
| Dispute bond | Same as `request.bondToken` | ETH: msg.value / ERC-20: transferFrom |
| DAO escalation bond | Always `daoEscalationBondToken` (Taiko ERC-20) | Always transferFrom |

## Forfeited Bond Distribution

Happens immediately within `resolveDispute` / `resolveDAOEscalation`, not deferred to `distributeRewards`.

| Outcome | Bond | Distribution |
|---|---|---|
| Dispute upheld | Disputer's bond forfeited | 50% to winners (split equally), 50% to requester |
| Dispute overturned | Disputer's bond returned | Full refund to disputer |
| DAO upheld | Escalator's bond forfeited | 50% to winners (split equally), 50% to requester |
| DAO overturned | Escalator's bond returned | Full refund to escalator |

No judge slashing in this implementation (hackathon scope).

## Impact on Existing Code

### Contract Changes

- **`Phase` enum:** Three new values appended: `DisputeWindow` (7), `Disputed` (8), `DAOEscalation` (9). Existing values `Distributed` (5) and `Failed` (6) unchanged — preserves UUPS storage compatibility.
- **`aggregate()`:** Transitions to `DisputeWindow` instead of `Finalized`. Sets `disputeWindowEnd`.
- **`distributeRewards()`:** Guard changes to require `DisputeWindow` phase AND `block.timestamp >= disputeWindowEnd[requestId]`.
- **`getResolution()`:** Returns `finalized = true` only when phase is `Distributed`. During `DisputeWindow`/`Disputed`/`DAOEscalation`, the answer exists but is still contestable, so `finalized` remains `false`. This keeps the ERC-8033 interface semantically correct — consumers can trust that `finalized = true` means the answer will not change.

### Existing Tests

- Tests calling `distributeRewards` after `aggregate` need `vm.warp` past the dispute window.
- Tests checking phase after `aggregate` need to expect `DisputeWindow` (7) instead of `Finalized` (4).
- All other tests (createRequest, commit, reveal, endCommitPhase, endRevealPhase) unchanged.

### Client Changes

- `PHASE_NAMES` array in web UI and TypeScript client updated for new phases.
- `isActivePhase()` treats `DisputeWindow`, `Disputed`, `DAOEscalation` as active.
- Worker does not need to handle dispute/DAO logic (those are user-initiated actions, not automated agent behavior).

## Test Plan

### New Tests

1. **Dispute happy path:** aggregate → dispute filed → dispute judge upholds → distribute
2. **Dispute overturn:** aggregate → dispute filed → dispute judge overturns with new winners → distribute (verify new winners get rewards)
3. **Dispute window expiry:** aggregate → warp past window → distribute directly (no dispute)
4. **Dispute bond validation:** insufficient bond reverts
5. **Dispute permissionless:** non-participant can file dispute
6. **Single dispute enforcement:** second dispute attempt reverts
7. **Dispute judge exclusion:** original judge cannot be dispute judge; reverts if only one judge in pool
8. **DAO escalation happy path:** dispute resolved → DAO escalation filed → DAO upholds → distribute
9. **DAO escalation overturn:** DAO overturns with new winners → distribute
10. **DAO escalation guards:** cannot escalate before dispute, cannot escalate twice, reverts if DAO not set
11. **DAO bond in Taiko ERC-20:** correct token transferred
12. **Forfeited bond distribution:** verify 50/50 split to winners and requester
13. **Full E2E flow:** create → commit → reveal → judge → dispute → DAO escalation → distribute
14. **Modified existing tests:** verify aggregate + warp + distribute still works
15. **Dispute at exact deadline:** filing at `block.timestamp == disputeWindowEnd` reverts (strict less-than)
16. **ETH sent with ERC-20 dispute bond:** reverts with `ETHSentWithERC20Bond`
17. **DAO escalation timeout:** DAO fails to act → `timeoutDAOEscalation` → escalator bond returned → distributable
18. **Zero dispute bond multiplier rejected:** `setDisputeBondMultiplier(0)` reverts
19. **Invalid bond token rejected:** `setDaoEscalationBondToken(address(0))` reverts

### Updated Existing Tests

- `test_aggregate()` — expect `DisputeWindow` (7) phase instead of `Finalized` (4)
- `test_distributeRewards_*` — add `vm.warp` past dispute window before calling distribute
- `test_fullFlow()` — add `vm.warp` past dispute window
- `test_getResolution_notFinalized()` — update: `DisputeWindow` phase returns `finalized = false`

## Accepted Risks (Hackathon Scope)

- **Pseudo-random dispute judge selection** reuses `blockhash`-based mechanism from `_transitionToJudging`. Sequencer-manipulable on L2. Accepted for hackathon; VRF is a future improvement.
- **Push-based bond distribution** in `resolveDispute`/`resolveDAOEscalation` could revert if a winner is a contract without `receive`. Consistent with existing `distributeRewards` pattern. Pull pattern is a future improvement.
- **Integer division dust** from 50/50 bond splits and per-winner division is not redistributed. Consistent with existing reward distribution. Dust remains in the contract.
- **No judge slashing** when a dispute is overturned. The original judge faces no penalty beyond not receiving additional compensation.
- **Judge removal between aggregation and dispute** — if the original judge is removed from the pool before a dispute, the exclusion filter is a no-op (harmless). If the dispute judge is removed after selection but before calling `resolveDispute`, their call still succeeds (consistent with existing `aggregate` behavior).
