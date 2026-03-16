# IPFS Content Storage for Nous Oracle Client

## Overview

Replace raw content posting on-chain with IPFS-backed storage. Agent answers and judge outputs are uploaded to IPFS via Pinata, and only the content-addressed CID is stored on-chain. This reduces gas costs and keeps bulky JSON payloads off-chain while preserving content integrity through IPFS's content-addressing.

## Decisions

- **What moves to IPFS:** Info agent reveal answers AND judge outputs (finalAnswer + reasoning). Commitments remain unchanged (already 32-byte hashes).
- **No smart contract changes:** The `bytes` fields already accept arbitrary data. They'll carry CID strings (hex-encoded) instead of full JSON (hex-encoded).
- **Pinning service:** Pinata via REST API. No IPFS node required.
- **Gateway:** Configurable via `IPFS_GATEWAY_URL` env var, defaults to `https://magenta-tremendous-cockroach-62.mypinata.cloud`.
- **Content format on IPFS:** Raw JSON (human-readable). Not hex-encoded.
- **Integration point:** IPFS upload/fetch happens in the worker layer, not in the agents or chain client. The chain client remains agnostic to what bytes it posts.
- **No new npm dependencies:** Uses native `fetch` for Pinata API and gateway calls.

## Architecture

### New Module: `client/src/ipfs.ts`

```typescript
interface IpfsService {
  upload(content: object): Promise<string>;   // returns CID
  fetch(cid: string): Promise<object>;        // fetches JSON from gateway
}
```

- `upload`: POSTs JSON to Pinata's `/pinning/pinJSONToIPFS` endpoint. Returns the `IpfsHash` (CID) from Pinata's response.
- `fetch`: GETs `https://<gateway>/ipfs/<CID>` and parses the JSON response.
- Auth via `PINATA_JWT` env var.

### Config Additions (`client/src/config.ts`)

| Env Var | Required | Default |
|---------|----------|---------|
| `PINATA_JWT` | Yes | — |
| `IPFS_GATEWAY_URL` | No | `https://magenta-tremendous-cockroach-62.mypinata.cloud` |

## Data Flow

### Commit Phase (handleCommitting)

```
Agent generates answer (JSON)
  -> Upload JSON to Pinata -> get CID
  -> Encode CID as hex: stringToHex(cid)
  -> Compute commitment: keccak256(cidHex || nonce)
  -> Store locally: { answer: cidHex, nonce, commitment }
  -> Submit commit(requestId, commitment) on-chain
```

The IPFS upload happens before commitment computation because the commitment hash must match the bytes that will be revealed (the CID hex, not the raw content).

### Reveal Phase (handleRevealing)

```
Retrieve stored { answer: cidHex, nonce } from local store
  -> Submit reveal(requestId, cidHex, nonce) on-chain
  -> Contract verifies: keccak256(cidHex || nonce) === stored commitment
```

No IPFS interaction — the CID hex was already stored locally during commit.

### Judge Phase (handleJudging)

```
Read revealedAnswers from chain -> array of CID hex strings
  -> For each: hexToString -> CID string
  -> Fetch JSON from IPFS gateway
  -> Parse into InfoAgentResult
  -> Pass decoded answers to judge agent LLM
  -> Judge produces finalAnswer + reasoning (JSON)
  -> Upload finalAnswer JSON to Pinata -> get CID1
  -> Upload reasoning JSON to Pinata -> get CID2
  -> Submit aggregate(requestId, stringToHex(CID1), winners, stringToHex(CID2))
```

## File Changes

| File | Change |
|------|--------|
| `client/src/ipfs.ts` (new) | `IpfsService` with `upload()` and `fetch()` methods |
| `client/src/config.ts` | Add `PINATA_JWT` and `IPFS_GATEWAY_URL` to env schema and config type |
| `client/src/worker.ts` | Inject `IpfsService`. Upload answers in `handleCommitting` before commitment. Fetch answers from IPFS in `handleJudging`. Upload judge outputs before `aggregate`. `decodeAnswer` becomes async. |
| `client/src/runtime.ts` | Create `IpfsService` instance from config, pass to worker |

### Unchanged Files

| File | Reason |
|------|--------|
| `client/src/chain.ts` | Receives hex bytes and posts them, agnostic to content |
| `client/src/infoAgent.ts` | Still returns `InfoAgentResult` JSON |
| `client/src/judgeAgent.ts` | Still returns `JudgeDecision` JSON |
| `client/src/types.ts` | `Hex` types remain, they just carry CIDs now |
| Smart contracts | `bytes` fields accept any data, no changes needed |

## Error Handling

- **Pinata upload fails during commit:** Agent hasn't committed yet. Fail loudly, worker retries on next tick.
- **Pinata upload fails during judge aggregation:** Judge hasn't submitted `aggregate` tx. Fail loudly, retry next tick.
- **IPFS gateway fetch fails during judging:** Judge can't evaluate without answers. Fail loudly, retry next tick. CIDs are permanent, so retry will succeed once gateway is reachable.
- **No retry within a single tick:** The worker already retries across ticks (every 5s default). Adding retry logic inside the IPFS service would be redundant.
