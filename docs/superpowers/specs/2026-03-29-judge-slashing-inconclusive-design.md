# Judge Slashing & Inconclusive Outcomes

## Overview

Add two mechanisms: (1) judges get their global stake slashed when their judgment is overturned by dispute or DAO, and (2) judges and DAO can declare "inconclusive" — refunding everything and restoring all slashed stakes.

## Judge Slashing

### When

Slash happens once at `distributeRewards()` time, not at dispute/DAO resolution time. This ensures only the final loser gets slashed, regardless of how many resolution layers were invoked.

### Mechanism

- Uses existing `_slashAgent(judge)` — deducts `slashPercentage` from global stake
- Slashed amount split 50/50: half to the challenger (disputer or DAO escalator), half added to `requestSlashedStake` (distributed to winners)
- Auto-deregisters judge if stake drops below `minStakeAmount` (existing mechanism)

### Who Gets Slashed

| Scenario | Slashed Judge |
|----------|--------------|
| No dispute filed | Nobody |
| Dispute upheld (not overturned), no DAO | Nobody |
| Dispute overturned, no DAO escalation | Original judge |
| Dispute upheld, DAO overturns | Dispute judge |
| Dispute overturned, DAO upholds | Original judge |
| Dispute overturned, DAO overturns | Dispute judge |
| Any inconclusive outcome | Nobody |

### New Storage

```solidity
/// @notice Judge to slash at distribution time (set during dispute/DAO resolution).
mapping(uint256 => address) public judgeToSlash;

/// @notice Beneficiary of 50% of slashed judge stake (disputer or DAO escalator).
mapping(uint256 => address) public slashBeneficiary;
```

### Contract Changes

**`resolveDispute()`** — when `overturn=true`:
- Set `judgeToSlash[requestId] = selectedJudge[requestId]` (original judge)
- Set `slashBeneficiary[requestId] = disputer[requestId]`

**`resolveDispute()`** — when `overturn=false`:
- Clear `judgeToSlash[requestId]` (judge was right, no slash)

**`resolveDAOEscalation()`** — when `overturn=true`:
- Set `judgeToSlash[requestId] = disputeJudge[requestId]` (dispute judge was wrong)
- Set `slashBeneficiary[requestId] = daoEscalator[requestId]`

**`resolveDAOEscalation()`** — when `overturn=false`:
- If `judgeToSlash[requestId]` was already set (from prior dispute overturn), keep it (original judge confirmed wrong)
- Set `slashBeneficiary[requestId] = daoEscalator[requestId]` if not already set

**`distributeRewards()`** — before distributing, if `judgeToSlash[requestId] != address(0)`:
1. `uint256 slashed = _slashAgent(judgeToSlash[requestId])`
2. `uint256 beneficiaryShare = slashed / 2`
3. `_transferToken(stakeToken, slashBeneficiary[requestId], beneficiaryShare)`
4. `requestSlashedStake[requestId] += (slashed - beneficiaryShare)`

---

## Inconclusive Outcomes

### Judge Inconclusive

**`aggregate()`** — remove the `if (winners.length == 0) revert NoWinners()` check. When `winners.length == 0`:
- Store empty winners array
- Skip loser slashing (no losers)
- Transition to DisputeWindow as normal (can still be disputed)
- `requestSlashedStake` from non-committers/non-revealers is kept (those agents still failed)

### DAO Inconclusive

**`resolveDAOEscalation()`** — add a third outcome. Change signature to accept a `uint8 outcome` parameter instead of `bool overturn`:
- `0 = uphold` (current `overturn=false`)
- `1 = overturn` (current `overturn=true`)
- `2 = inconclusive`

### Inconclusive Resolution (at distribution time)

When `winners.length == 0` at `distributeRewards()`:

1. **Refund requester** — return `rewardAmount` in `rewardToken`
2. **Restore all slashed agent stakes** — iterate `_slashedAgents[requestId]`, add `_slashedAmounts[requestId][agent]` back to `agentStakes[agent].amount`. Re-register if amount >= `minStakeAmount` and not registered.
3. **Return dispute bond** — if `disputeUsed[requestId]`, return `disputeBondPaid[requestId]` to `disputer[requestId]`
4. **Return DAO escalation bond** — if `daoEscalationUsed[requestId]`, return `daoEscalationBondPaid[requestId]` to `daoEscalator[requestId]`
5. **No judge slash** — clear `judgeToSlash[requestId]`
6. **Decrement active assignments** for all selected/committed agents
7. **Phase → Failed**

### New Storage for Slash Tracking

```solidity
/// @notice Agents slashed during this request (for potential restore on inconclusive).
mapping(uint256 => address[]) internal _slashedAgents;

/// @notice Amount slashed per agent per request.
mapping(uint256 => mapping(address => uint256)) internal _slashedAmounts;
```

### Changes to `_slashAgent`

`_slashAgent` currently doesn't track per-request slashing. Add a variant or modify it to also record the slash:

```solidity
function _slashAgentForRequest(uint256 requestId, address agent) internal returns (uint256 slashed) {
    slashed = _slashAgent(agent);
    if (slashed > 0) {
        _slashedAgents[requestId].push(agent);
        _slashedAmounts[requestId][agent] += slashed;
    }
}
```

Replace all `_slashAgent` calls in `endCommitPhase`, `endRevealPhase`, and `aggregate` with `_slashAgentForRequest`.

---

## What Does NOT Change

- Info agent slashing for non-commit, non-reveal, losing (still happens during phase transitions)
- Registration, withdrawal, staking mechanics
- Dispute filing and bond collection
- Frontend dispute modal (already shows bond amount)
- Client worker logic
