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

## Docker Compose

This repo also supports a manifest-driven launcher for running any local mix of info agents and judge agents, with one model per agent.

Setup:

```bash
# from the repo root
cp .env.example .env
cp agents.example.json agents.json
mkdir -p state
```

Edit the top-level `agents.json` to define your local agents:

```json
{
  "agents": [
    {
      "id": "info-1",
      "role": "info",
      "model": "openai/gpt-4.1-mini",
      "privateKey": "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "id": "judge-1",
      "role": "judge",
      "model": "anthropic/claude-3.7-sonnet",
      "privateKey": "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
```

Set the shared runtime environment in the top-level `.env` file:

```env
RPC_URL=http://host.docker.internal:8545
ORACLE_ADDRESS=0x0000000000000000000000000000000000000001
CHAIN_ID=167
OPENROUTER_API_KEY=your_openrouter_api_key
POLL_INTERVAL_MS=5000
```

Then start all agents:

```bash
docker compose up --build agents
```

The launcher will start one worker per manifest entry and persist state under the top-level `state/` directory.

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

Run the manifest-driven launcher directly without Docker:

```bash
cd client
AGENTS_FILE=../agents.json STATE_DIR=../state node dist/launcher.js
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
- The launcher can run multiple agents concurrently from a local manifest, each with its own model
