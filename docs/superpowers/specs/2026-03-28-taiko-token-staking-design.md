# Switch Staking & Bonds to Taiko Token

## Overview

Change all staking, rewards, and dispute bonds from native ETH to the Taiko ERC-20 token (`0x557f5b2b222f1f59f94682df01d35dd11f37939a` on Hoodi). This unifies the protocol around a single token.

## Changes

### Contract (`NousOracle.sol`)

1. **`createRequest()`** — For staking-model requests (`bondAmount == 0`), require `rewardToken == stakeToken`. Revert with a new error `RewardTokenMustBeStakeToken` if mismatched.

2. **`initiateDispute()`** — For staking-model requests, collect dispute bond in `stakeToken` instead of `req.bondToken` (which is `address(0)` for staking model). Use `IERC20(stakeToken).safeTransferFrom()` instead of checking `req.bondToken`.

3. **`resolveDispute()`** — For staking-model requests, return/distribute dispute bond using `stakeToken` instead of `req.bondToken`.

4. **`distributeRewards()`** staking path — No code change needed. It already sends `rewardPerWinner + slashPerWinner` via `req.rewardToken`, which now equals `stakeToken`. Both reward and slashed stake are in the same token.

5. **`_distributeForfeitedBond()`** calls from `resolveDispute()` — For staking model, pass `stakeToken` instead of `req.bondToken`.

### Upgrade Script (`Upgrade.s.sol`)

Set `stakeToken` to Taiko token address. Add new env var `STAKE_TOKEN` with the address.

### Client (`chain.ts`)

1. **`registerAgent()`** — Instead of `value: minStake`, do ERC-20 approve + `registerAgent()` call without value. Read `stakeToken` from contract, approve it, then call `registerAgent`.

2. **`addStake()`** — Same ERC-20 approve flow instead of `value: amount`.

### Frontend (`web/index.html`)

1. Create request form — set `rewardToken` to Taiko token address (hardcoded `0x557f5b2b222f1f59f94682df01d35dd11f37939a`) instead of `address(0)`.

2. Update reward display to show "TAIKO" instead of "ETH" for staking-model requests.

### Tests (`NousOracle.t.sol`)

Update staking tests to use MockERC20 as the stake token:
- `_setupStaking()` — call `oracle.setStakeToken(address(token))` (need new setter or set via upgrade initializer)
- Registration tests — mint tokens, approve, then call `registerAgent()` without `msg.value`
- All staking flow tests — use token balances instead of ETH balances

## What Does NOT Change

- Legacy bond-model requests (bondAmount > 0) — still work with any token
- Commit-reveal cryptography
- Judge selection logic
- DAO escalation (already uses its own `daoEscalationBondToken`)
- Withdrawal flow — `_transferToken(stakeToken, ...)` already handles ERC-20
- `_slashAgent()` — just decrements `stake.amount`, no token transfer
