# Nous Agent Client

Node/TypeScript worker for running `infoAgents` and `judgeAgents` against `NousOracle`.

## Environment

Required:

- `RPC_URL`
- `ORACLE_ADDRESS`
- `CHAIN_ID`
- `MODEL_ID`
- `INFO_AGENT_PRIVATE_KEYS`
- `JUDGE_AGENT_PRIVATE_KEYS`
- `OPENROUTER_API_KEY`

Optional:

- `POLL_INTERVAL_MS`
- `STATE_FILE`

Private key lists are comma-separated `0x...` values.

## Commands

Install dependencies:

```bash
cd client
npm install
```

Run the long-lived worker:

```bash
cd client
npm run build
node dist/cli.js worker
```

Run a one-shot info-agent pass for a single request:

```bash
cd client
node dist/cli.js run-info --request 1
```

Run a one-shot judge pass for a single request:

```bash
cd client
node dist/cli.js run-judge --request 1
```

## Behavior

- Polls active requests from the oracle
- Submits `commit` transactions for configured info-agent wallets
- Persists commit material locally so later `reveal` calls can be reconstructed
- Detects the selected judge and submits `aggregate`
- Advances expired commit and reveal phases by calling `endCommitPhase` and `endRevealPhase`
