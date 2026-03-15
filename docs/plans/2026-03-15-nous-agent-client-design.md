# Nous Agent Client Design

**Date:** 2026-03-15

**Goal**

Build a standalone TypeScript client in `client/` that can run `infoAgents` and `judgeAgents` against `NousOracle`, using local private keys to submit `commit`, `reveal`, and `aggregate` transactions onchain.

**Scope**

- Create a Node/TypeScript package in `client/`
- Use `viem` for chain reads and writes
- Use the Vercel AI SDK for model-driven answer generation and judging
- Support long-running worker mode plus one-shot commands
- Persist commit/reveal material locally so restarts do not lose reveal capability

**Out of Scope**

- Browser UI
- Multi-chain orchestration
- Advanced scheduling beyond a polling loop
- External secret managers or hosted persistence

## Protocol Mapping

The onchain protocol exposes three actions the client needs to automate:

1. `commit(requestId, commitment)` for info agents during the commit phase
2. `reveal(requestId, answer, nonce)` for info agents during the reveal phase
3. `aggregate(requestId, finalAnswer, winners, reasoning)` for the selected judge during the judging phase

The client also needs request metadata and status from:

- `getRequest(requestId)`
- `getCommits(requestId)`
- `getReveals(requestId)`
- `getResolution(requestId)`
- public mappings and view functions on `NousOracle` such as `phases`, `selectedJudge`, and `revealDeadlines`

## Recommended Architecture

Use a layered package with a reusable protocol client underneath one worker runtime.

### Layer 1: Chain Client

Encapsulate contract reads, writes, ABI encoding, and phase detection.

Responsibilities:

- Read request state from `NousOracle`
- Submit transactions with configured wallets
- Normalize raw contract responses into TypeScript objects
- Expose safe helpers like `canCommit`, `canReveal`, and `canAggregate`

### Layer 2: Agent Runtime

Encapsulate role-specific behavior for info agents and judge agents.

Responsibilities:

- Build prompts from request metadata
- Call the model through the AI SDK
- Validate and normalize model output
- Encode final answer and reasoning payloads as `bytes`

### Layer 3: Worker Loop

Drive polling, persistence, retries, and phase transitions.

Responsibilities:

- Discover active request IDs
- Decide which role actions are eligible for each configured wallet
- Persist info-agent answers and nonces before broadcast
- Retry recoverable failures without duplicating onchain actions

## Package Shape

`client/` will contain:

- a library entrypoint for programmatic use
- a CLI entrypoint for operators
- runtime stores and validation utilities

Planned public surface:

- `createNousClient(config)`
- `runWorker()`
- `runInfoAgentOnce(requestId)`
- `runJudgeOnce(requestId)`

Planned CLI commands:

- `nous-worker`
- `nous-run-info --request <id>`
- `nous-run-judge --request <id>`

## Answer Schema

Info agents should produce structured JSON that the client serializes to bytes:

```json
{
  "answer": "string",
  "confidence": 0.0,
  "reasoning": "string",
  "sources": ["https://example.com"]
}
```

Judge agents should consume revealed info-agent answers and produce:

```json
{
  "finalAnswer": "string",
  "reasoning": "string",
  "winnerAddresses": ["0x..."]
}
```

The worker will validate model output before submitting transactions. Invalid outputs are rejected locally rather than sent onchain.

## Persistence Model

Commit-reveal requires the exact reveal payload used to compute the original commitment. The client therefore needs a durable local store keyed by `requestId` and wallet address.

Persisted fields:

- wallet address
- request ID
- encoded answer bytes
- nonce
- commitment hash
- commit transaction hash
- reveal submitted flag

A simple JSON file store is sufficient for the first cut.

## Operational Rules

- Never submit `commit` twice from the same wallet for the same request
- Never submit `reveal` without matching locally persisted answer and nonce
- Never submit `aggregate` unless the configured wallet equals the onchain selected judge
- Validate that every proposed winner appears in the revealed agent set before calling `aggregate`
- Treat model output as untrusted input

## Configuration

Environment-driven configuration is sufficient for the first version.

Expected configuration:

- RPC URL
- oracle contract address
- chain ID
- polling interval
- AI model identifier
- AI provider API key
- one or more info-agent private keys
- one or more judge private keys
- path to the local state file

## Testing Strategy

Use TDD for the client package.

Focus on:

- commitment hashing and reveal payload persistence
- output validation for info and judge agent responses
- chain state gating for commit, reveal, and aggregate actions
- worker behavior against mocked contract reads and wallet writes

Defer real end-to-end chain integration until the package surface is stable.

## Tradeoffs

Why one worker runtime instead of separate binaries first:

- less duplicated chain logic
- easier local testing and hackathon iteration
- reusable abstractions can still support split deployment later

Why JSON file persistence instead of a database:

- enough durability for the first version
- simpler local setup
- preserves the critical reveal material needed after restarts

## Acceptance Criteria

- `client/` is a runnable TypeScript package
- an operator can start a worker with env configuration
- info-agent wallets can commit and later reveal against `NousOracle`
- a judge wallet can detect selection and call `aggregate`
- local tests cover the commit/reveal/judge decision logic
