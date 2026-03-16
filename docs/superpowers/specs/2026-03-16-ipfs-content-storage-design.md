# IPFS Content Storage for Nous Oracle Client

## Overview

Replace raw content posting on-chain with IPFS-backed storage. Agent answers and judge outputs are uploaded to IPFS via Pinata, and only the content-addressed CID is stored on-chain. This reduces gas costs and keeps bulky JSON payloads off-chain while preserving content integrity through IPFS's content-addressing.

## Decisions

- **What moves to IPFS:** Info agent reveal answers AND judge outputs (finalAnswer + reasoning). Commitments remain unchanged (already 32-byte hashes).
- **No smart contract changes:** The `bytes` fields already accept arbitrary data. They'll carry CID strings (hex-encoded) instead of full JSON (hex-encoded).
- **Pinning service:** Pinata via REST API. No IPFS node required.
- **Gateway:** Configurable via `IPFS_GATEWAY_URL` env var, defaults to `https://magenta-tremendous-cockroach-62.mypinata.cloud`.
- **Content format on IPFS:** Info agent results are uploaded as JSON objects. Judge `finalAnswer` and `reasoning` are plain strings, so they are wrapped in `{ "content": "<value>" }` before upload to maintain valid JSON on IPFS.
- **Integration point:** IPFS upload/fetch happens in the worker layer, not in the agents or chain client. The chain client remains agnostic to what bytes it posts.
- **No new npm dependencies:** Uses native `fetch` for Pinata API and gateway calls.
- **Fail-fast on missing config:** If `PINATA_JWT` is not set, the client refuses to start (Zod validation failure at config load time).

## Architecture

### New Module: `client/src/ipfs.ts`

```typescript
interface IpfsService {
  upload(content: object): Promise<string>;   // returns CID (validated)
  fetch(cid: string): Promise<unknown>;       // fetches JSON from gateway
}
```

- `upload`: POSTs JSON to Pinata's `/pinning/pinJSONToIPFS` endpoint. Returns the `IpfsHash` (CID) from Pinata's response. Validates the returned CID matches expected format (CIDv0 `Qm...` or CIDv1 `bafy...`) before returning.
- `fetch`: GETs `https://<gateway>/ipfs/<CID>` and parses the JSON response.
- Auth via `PINATA_JWT` env var (Bearer token in Authorization header).

### Config Additions (`client/src/config.ts`)

| Env Var | Required | Default |
|---------|----------|---------|
| `PINATA_JWT` | Yes | — (client refuses to start if absent) |
| `IPFS_GATEWAY_URL` | No | `https://magenta-tremendous-cockroach-62.mypinata.cloud` |

These are added to `NousClientConfig` as `pinataJwt: string` and `ipfsGatewayUrl: string`.

## Data Flow

### Commit Phase (handleCommitting)

```
Agent generates answer (InfoAgentResult JSON object)
  -> Upload JSON object to Pinata -> get CID
  -> Encode CID as hex: stringToHex(cid) -> cidHex
  -> Compute commitment via computeCommitment(cidHex, nonce)
     (uses ABI encoding: keccak256(abi.encode(cidHex, nonce)))
  -> Store locally: { answer: cidHex, nonce, commitment }
  -> Submit commit(requestId, commitment) on-chain
```

Key changes from current flow:
- `encodeInfoAgentResult(result)` is **no longer called** in the commit path. Instead, the raw `InfoAgentResult` object is uploaded to IPFS, and the CID hex replaces the encoded answer.
- The IPFS upload happens before commitment computation because the commitment hash must match the bytes that will be revealed (the CID hex, not the raw content).

### Reveal Phase (handleRevealing)

```
Retrieve stored { answer: cidHex, nonce } from local store
  -> Submit reveal(requestId, cidHex, nonce) on-chain
  -> Contract verifies via ABI encoding: keccak256(abi.encode(cidHex, nonce)) === stored commitment
```

No IPFS interaction — the CID hex was already stored locally during commit.

### Judge Phase (handleJudging)

The current `decodeAnswer` function (sync, hex-to-JSON) is replaced with an async `resolveAnswer` function that fetches content from IPFS:

```
Read revealedAnswers from chain -> array of CID hex strings
  -> For each (in parallel via Promise.all):
     -> hexToString(cidHex) -> CID string
     -> Fetch JSON from IPFS gateway: ipfs.fetch(cid)
     -> Parse via parseInfoAgentResult() -> InfoAgentResult
     -> Construct DecodedInfoAnswer { rawAnswer: cidHex, parsedAnswer, text }
  -> If any single fetch fails, the entire judge pass fails (retry next tick)
  -> Pass decoded answers to judge agent LLM
  -> Judge produces { finalAnswer: string, reasoning: string, winnerAddresses }
  -> Upload { content: finalAnswer } to Pinata -> get CID1
  -> Upload { content: reasoning } to Pinata -> get CID2
  -> Submit aggregate(requestId, stringToHex(CID1), winners, stringToHex(CID2))
```

IPFS gateway fetches are done in parallel since answers are independent. No per-fetch timeout beyond the default HTTP timeout — if the gateway is slow, the entire tick will eventually time out and retry.

## File Changes

| File | Change |
|------|--------|
| `client/src/ipfs.ts` (new) | `IpfsService` with `upload()` and `fetch()` methods, CID validation |
| `client/src/config.ts` | Add `PINATA_JWT` (required) and `IPFS_GATEWAY_URL` (optional, default gateway) to env schema and `NousClientConfig` |
| `client/src/worker.ts` | Inject `IpfsService` into `WorkerConfig`. In `handleCommitting`: upload result to IPFS, use CID hex as `answer` (replaces `encodeInfoAgentResult`). Replace sync `decodeAnswer` with async `resolveAnswer` that fetches from IPFS. In `handleJudging`: use `resolveAnswer` with `Promise.all`, wrap judge `finalAnswer`/`reasoning` strings in `{ content }` envelope before upload, use CIDs for `aggregate`. |
| `client/src/runtime.ts` | Create `IpfsService` instance from config, pass to worker |
| `client/src/launcher.ts` | Pass IPFS config through to runtime |
| `web/index.html` | Update `tryDecodeHex` to detect CID strings (starts with `Qm` or `bafy`) and fetch content from the IPFS gateway. Add `IPFS_GATEWAY_URL` as a configurable constant. Falls back to current raw JSON decode for pre-IPFS on-chain data. |

### Unchanged Files

| File | Reason |
|------|--------|
| `client/src/chain.ts` | Receives hex bytes and posts them, agnostic to content |
| `client/src/infoAgent.ts` | Still returns `InfoAgentResult` JSON object |
| `client/src/judgeAgent.ts` | Still returns `JudgeDecision` |
| `client/src/types.ts` | `Hex` types remain, they just carry CIDs now |
| Smart contracts | `bytes` fields accept any data, no changes needed |

## Backward Compatibility

The web UI must handle both old (raw JSON hex) and new (CID hex) on-chain data:

- **Detection heuristic:** After `hexToString`, if the decoded string starts with `Qm` (CIDv0) or `bafy` (CIDv1), treat it as a CID and fetch from IPFS gateway. Otherwise, treat as raw JSON (existing behavior).
- **Client worker:** Does not need backward compatibility — it only writes new data. It reads via `resolveAnswer` which only runs during active judging phases on new requests.

## Error Handling

- **Pinata upload fails during commit:** Agent hasn't committed yet. Fail loudly, worker retries on next tick.
- **Pinata upload fails during judge aggregation:** Judge hasn't submitted `aggregate` tx. Fail loudly, retry next tick.
- **IPFS gateway fetch fails during judging:** Judge can't evaluate without answers. Entire judge pass fails, retry next tick. CIDs are permanent, so retry will succeed once gateway is reachable.
- **No retry within a single tick:** The worker already retries across ticks (every 5s default). Adding retry logic inside the IPFS service would be redundant.
- **Invalid CID from Pinata:** `upload()` validates the returned hash matches CID format before returning. Throws if invalid.
- **Pinata rate limits:** Not handled specially. Rate limit errors (429) will cause the tick to fail and retry on the next cycle. For this project's scale (few agents, few requests), this is unlikely to be an issue.
