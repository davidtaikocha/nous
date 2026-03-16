# Nous

**AI Agent Council Oracle**

Nous is a decentralized oracle protocol that enables smart contracts to ask arbitrary natural language questions and receive economically-secured, consensus-driven answers from AI agent councils. Built on [ERC-8033 (Agent Council Oracle)](https://eips.ethereum.org/EIPS/eip-8033).

## Overview

Nous solves the "semantic oracle problem" — how to get reliable, verifiable answers to open-ended questions on-chain. Instead of relying on a single oracle feed, Nous assembles a council of independent AI agents that stake bonds, submit answers through a commit-reveal scheme, and are judged by a randomly-selected peer. Correct agents earn rewards; incorrect agents lose their bonds.

All answer content is stored on IPFS via Pinata, with only content-addressed CIDs posted on-chain — reducing gas costs while preserving verifiability.

## Protocol Flow

```
1. Request    — dApp or user submits a query + reward + bond parameters
2. Commit     — Info agents stake bonds and submit hashed answers (keccak256)
3. Reveal     — Agents reveal answers; quorum (>50%) required to proceed
4. Judge      — Randomly-selected judge synthesizes answers and picks winners
5. Distribute — Winners receive: reward share + bond refund + slashed bonds from losers
```

```
createRequest("Did company X announce bankruptcy?")
  → Info agents commit/reveal via IPFS
  → Judge aggregates consensus
  → getResolution() → dApp acts on the answer
```

## Architecture

### Smart Contracts

| File | Description |
|------|-------------|
| `src/IAgentCouncilOracle.sol` | ERC-8033 standard interface |
| `src/NousOracle.sol` | Core implementation (UUPS upgradeable) |

- Supports both native ETH and ERC-20 tokens for rewards and bonds
- Owner-managed judge pool with random selection per request
- Bond slashing for non-revealing or losing agents, redistributed to winners

### Agent Client

| File | Description |
|------|-------------|
| `client/src/worker.ts` | Core orchestration — polls requests, manages commit/reveal/judge lifecycle |
| `client/src/infoAgent.ts` | Info agent LLM integration via OpenRouter |
| `client/src/judgeAgent.ts` | Judge agent LLM integration |
| `client/src/ipfs.ts` | IPFS service — upload to Pinata, fetch from gateway |
| `client/src/chain.ts` | On-chain read/write via Viem |
| `client/src/store.ts` | Local state persistence for commit-reveal material |
| `client/src/launcher.ts` | Manifest-driven multi-agent orchestrator |

### IPFS Storage

Answers and judge outputs are stored on IPFS rather than on-chain:

- **Info agent answers** — JSON uploaded to Pinata, CID stored on-chain as `bytes`
- **Judge outputs** — `finalAnswer` and `reasoning` uploaded as `{ content: "..." }` envelopes
- **Request queries** — Requesters can optionally store queries on IPFS (CID in the `query` field)
- **Backward compatible** — the client detects CIDs (`Qm...` / `bafy...`) and resolves them; raw on-chain data still works

### Web UI

A real-time dashboard at `web/index.html` showing the oracle pipeline, agent council, and live request cards with IPFS-resolved content.

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (for contracts)
- Node.js >= 22 (for agent client)
- Docker + Docker Compose (for containerized deployment)
- [OpenRouter](https://openrouter.ai/) API key (for LLM access)
- [Pinata](https://www.pinata.cloud/) account + JWT (for IPFS storage)

### Build Contracts

```bash
forge build
forge test
```

### Deploy

```bash
PRIVATE_KEY=<key> OWNER=<address> forge script script/Deploy.s.sol \
  --rpc-url <rpc_url> --broadcast
```

Set `REVEAL_DURATION` (seconds) to customize the reveal window (default: 1 hour).

### Run Agents (Docker Compose)

```bash
# 1. Configure environment
cp .env.example .env
cp agents.example.json agents.json
mkdir -p state

# 2. Edit .env with your RPC, contract address, API keys
# 3. Edit agents.json with agent roles, models, and private keys

# 4. Start agents + web UI
docker compose up --build
```

The web UI is available at `http://localhost:3001`.

### Run Agents (Manual)

```bash
cd client
npm install
npm run build

# Long-lived worker
node dist/cli.js worker

# Or manifest-driven launcher
AGENTS_FILE=../agents.json STATE_DIR=../state node dist/launcher.js
```

## Configuration

### Environment Variables (`.env`)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RPC_URL` | Yes | — | JSON-RPC endpoint |
| `ORACLE_ADDRESS` | Yes | — | Deployed NousOracle contract address |
| `CHAIN_ID` | Yes | — | Chain ID |
| `OPENROUTER_API_KEY` | Yes | — | OpenRouter API key for LLM access |
| `PINATA_JWT` | Yes | — | Pinata JWT for IPFS uploads |
| `IPFS_GATEWAY_URL` | No | `https://gateway.pinata.cloud` | IPFS gateway for content retrieval |
| `POLL_INTERVAL_MS` | No | `5000` | Polling interval in milliseconds |

### Agent Manifest (`agents.json`)

```json
{
  "agents": [
    {
      "id": "info-1",
      "role": "info",
      "model": "deepseek/deepseek-v3.2",
      "privateKey": "0x..."
    },
    {
      "id": "judge-1",
      "role": "judge",
      "model": "x-ai/grok-4.1-fast",
      "privateKey": "0x..."
    }
  ]
}
```

Each agent gets its own wallet (private key) and LLM model via OpenRouter. The `role` determines behavior:
- `info` — generates answers to queries using web search + LLM reasoning
- `judge` — evaluates revealed answers, synthesizes a final answer, selects winners

## Use Cases

- **Insurance** — auto-resolve claims based on real-world events
- **Prediction Markets** — resolve markets without human operators
- **Governance** — verify proposals against DAO constitutions
- **Compliance** — real-time sanctions and regulatory checks
- **Dynamic NFTs** — NFTs that react to real-world data
- **Lending** — assess off-chain collateral (real estate, patents, equities)

## License

MIT
