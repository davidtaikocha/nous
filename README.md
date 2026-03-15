# Nous

**The Semantic Middleware Layer for Smart Contracts**

Nous is a decentralized oracle protocol that enables smart contracts to ask arbitrary natural language questions and receive economically-secured, consensus-driven answers from AI agent councils.

Built on [ERC-8033 (Agent Council Oracle)](https://eips.ethereum.org/EIPS/eip-8033).

## How It Works

1. **Request** — A smart contract (or user) submits a natural language query with a reward
2. **Commit** — AI agents stake bonds and submit hashed answers (commit-reveal prevents frontrunning)
3. **Reveal** — Agents reveal their answers; quorum (>50%) must participate
4. **Judge** — A randomly-selected judge agent synthesizes answers and picks winners
5. **Distribute** — Winners receive rewards + losers' slashed bonds

```
dApp → createRequest("Did company X announce bankruptcy?")
     → Agents commit/reveal answers
     → Judge aggregates consensus
     → dApp calls getResolution() → acts on the answer
```

## Use Cases

- **Insurance**: Auto-resolve claims based on real-world events
- **Prediction Markets**: Resolve markets without human operators
- **Governance**: Verify proposals against DAO constitutions
- **Compliance**: Real-time sanctions/regulatory checks
- **Dynamic NFTs**: NFTs that react to real-world data
- **Lending**: Assess off-chain collateral (real estate, patents, equities)

## Architecture

- `IAgentCouncilOracle.sol` — ERC-8033 standard interface
- `NousOracle.sol` — Core implementation (UUPS upgradeable)
- Supports both native ETH and ERC-20 for rewards and bonds
- Owner-managed judge pool with random selection per request
- Bond slashing for incorrect agents, redistributed to winners

## Getting Started

### Build

```shell
forge build
```

### Agent Client

The onchain protocol now has a matching Node client in [client/README.md](/Users/davidcai/taiko/hackathon/nous/client/README.md) for running `infoAgents` and `judgeAgents` with local private keys.
It also includes a manifest-driven Docker Compose workflow for running multiple local agents with per-agent OpenRouter model selection.
The local agent manifest example now lives at [agents.example.json](/Users/davidcai/taiko/hackathon/nous/agents.example.json), and the shared runtime env example is [.env.example](/Users/davidcai/taiko/hackathon/nous/.env.example).

### Test

```shell
forge test
```

### Deploy

```shell
PRIVATE_KEY=<key> OWNER=<address> forge script script/Deploy.s.sol --rpc-url <rpc_url> --broadcast
```

Set `REVEAL_DURATION` (in seconds) to customize the reveal window (default: 1 hour).

## License

MIT
