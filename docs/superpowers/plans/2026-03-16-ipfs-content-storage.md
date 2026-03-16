# IPFS Content Storage Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace raw on-chain content posting with IPFS-backed storage via Pinata — upload JSON to IPFS, store only the CID on-chain.

**Architecture:** A new `IpfsService` module handles Pinata upload/gateway fetch. The worker layer uses it to upload content before on-chain writes and fetch content when reading revealed answers. Agents and chain client remain unchanged.

**Tech Stack:** TypeScript, Vitest, native `fetch`, Pinata REST API, Viem

**Spec:** `docs/superpowers/specs/2026-03-16-ipfs-content-storage-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `client/src/ipfs.ts` (create) | `IpfsService` — upload JSON to Pinata, fetch JSON from gateway, CID validation |
| `client/src/ipfs.test.ts` (create) | Tests for IpfsService (mocked fetch) |
| `client/src/config.ts` (modify) | Add `PINATA_JWT`, `IPFS_GATEWAY_URL` to env schema and config type |
| `client/src/worker.ts` (modify) | Inject `IpfsService`, upload in commit path, async resolve in judge path |
| `client/src/runtime.ts` (modify) | Create `IpfsService` instance, pass to worker |
| `client/src/launcher.ts` (no changes) | Config already flows through via `buildMergedConfig` spread |
| `client/src/index.ts` (modify) | Re-export ipfs module |
| `web/index.html` (modify) | Update `tryDecodeHex` to detect CIDs and fetch from IPFS gateway |
| `.env.example` (modify) | Add new env vars |

---

## Chunk 1: IpfsService Module

### Task 1: Create `IpfsService` with `upload` and `fetch`

**Files:**
- Create: `client/src/ipfs.ts`
- Create: `client/src/ipfs.test.ts`

- [ ] **Step 1: Write failing tests for `createIpfsService`**

Create `client/src/ipfs.test.ts`:

```typescript
import { describe, expect, it, vi, beforeEach } from 'vitest';
import { createIpfsService } from './ipfs.js';

describe('createIpfsService', () => {
  const mockFetch = vi.fn();

  beforeEach(() => {
    mockFetch.mockReset();
  });

  describe('upload', () => {
    it('uploads JSON to Pinata and returns CID', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ IpfsHash: 'QmTestHash123456789012345678901234567890123' }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      const cid = await ipfs.upload({ answer: 'hello', confidence: 0.9 });

      expect(cid).toBe('QmTestHash123456789012345678901234567890123');
      expect(mockFetch).toHaveBeenCalledWith(
        'https://api.pinata.cloud/pinning/pinJSONToIPFS',
        expect.objectContaining({
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: 'Bearer test-jwt',
          },
          body: JSON.stringify({ pinataContent: { answer: 'hello', confidence: 0.9 } }),
        }),
      );
    });

    it('throws on non-ok response', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 401,
        text: async () => 'Unauthorized',
      });

      const ipfs = createIpfsService({
        pinataJwt: 'bad-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.upload({ data: 'test' })).rejects.toThrow('Pinata upload failed (401)');
    });

    it('throws on invalid CID format', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ IpfsHash: 'not-a-valid-cid' }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.upload({ data: 'test' })).rejects.toThrow('Invalid CID');
    });
  });

  describe('fetch', () => {
    it('fetches JSON from IPFS gateway', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ answer: 'hello', confidence: 0.9 }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      const result = await ipfs.fetch('QmTestHash123456789012345678901234567890123');

      expect(result).toEqual({ answer: 'hello', confidence: 0.9 });
      expect(mockFetch).toHaveBeenCalledWith(
        'https://test.mypinata.cloud/ipfs/QmTestHash123456789012345678901234567890123',
      );
    });

    it('throws on non-ok response', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 404,
        text: async () => 'Not Found',
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.fetch('QmTestHash123456789012345678901234567890123')).rejects.toThrow(
        'IPFS fetch failed (404)',
      );
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd client && npx vitest run src/ipfs.test.ts`
Expected: FAIL — module `./ipfs.js` does not exist

- [ ] **Step 3: Implement `createIpfsService`**

Create `client/src/ipfs.ts`:

```typescript
const CID_PATTERN = /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]{55,})$/;

export interface IpfsService {
  upload(content: object): Promise<string>;
  fetch(cid: string): Promise<unknown>;
}

interface IpfsServiceConfig {
  pinataJwt: string;
  gatewayUrl: string;
  fetchFn?: typeof globalThis.fetch;
}

export function createIpfsService({
  pinataJwt,
  gatewayUrl,
  fetchFn = globalThis.fetch,
}: IpfsServiceConfig): IpfsService {
  return {
    async upload(content: object): Promise<string> {
      const response = await fetchFn('https://api.pinata.cloud/pinning/pinJSONToIPFS', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${pinataJwt}`,
        },
        body: JSON.stringify({ pinataContent: content }),
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(`Pinata upload failed (${response.status}): ${text}`);
      }

      const data = (await response.json()) as { IpfsHash: string };
      const cid = data.IpfsHash;

      if (!CID_PATTERN.test(cid)) {
        throw new Error(`Invalid CID returned from Pinata: ${cid}`);
      }

      return cid;
    },

    async fetch(cid: string): Promise<unknown> {
      const url = `${gatewayUrl}/ipfs/${cid}`;
      const response = await fetchFn(url);

      if (!response.ok) {
        const text = await response.text();
        throw new Error(`IPFS fetch failed (${response.status}): ${text}`);
      }

      return response.json();
    },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd client && npx vitest run src/ipfs.test.ts`
Expected: All 5 tests PASS

- [ ] **Step 5: Add re-export in `index.ts`**

Add to `client/src/index.ts`:

```typescript
export * from './ipfs.js';
```

- [ ] **Step 6: Commit**

```bash
git add client/src/ipfs.ts client/src/ipfs.test.ts client/src/index.ts
git commit -m "feat: add IpfsService module for Pinata upload and gateway fetch"
```

---

## Chunk 2: Config Changes

### Task 2: Add IPFS config to env schema

**Files:**
- Modify: `client/src/config.ts`
- Modify: `.env.example`

- [ ] **Step 1: Update env schema in `config.ts`**

In `client/src/config.ts`, add to the `envSchema` object (after `JUDGE_AGENT_PRIVATE_KEYS`):

```typescript
PINATA_JWT: z.string().min(1),
IPFS_GATEWAY_URL: z.string().url().default('https://magenta-tremendous-cockroach-62.mypinata.cloud'),
```

Add to `NousClientConfig` interface:

```typescript
pinataJwt: string;
ipfsGatewayUrl: string;
```

Add to the return object of `loadConfig`:

```typescript
pinataJwt: env.PINATA_JWT,
ipfsGatewayUrl: env.IPFS_GATEWAY_URL,
```

- [ ] **Step 2: Update `.env.example`**

Add to `.env.example`:

```
PINATA_JWT=your_pinata_jwt
IPFS_GATEWAY_URL=https://magenta-tremendous-cockroach-62.mypinata.cloud
```

- [ ] **Step 3: Run existing tests to verify nothing broke**

Run: `cd client && npx vitest run`
Expected: All existing tests pass. Note: `index.test.ts` creates a client with `{} as never` which bypasses config validation, so this won't break.

- [ ] **Step 4: Commit**

```bash
git add client/src/config.ts .env.example
git commit -m "feat: add PINATA_JWT and IPFS_GATEWAY_URL config"
```

---

## Chunk 3: Worker Integration

### Task 3: Inject IpfsService into worker and update commit path

**Files:**
- Modify: `client/src/worker.ts`

- [ ] **Step 1: Add `IpfsService` to `WorkerConfig`**

In `client/src/worker.ts`, add import:

```typescript
import type { IpfsService } from './ipfs.js';
```

Add to `WorkerConfig` interface (after `judgeAgents`):

```typescript
ipfs: IpfsService;
```

Add `ipfs` to the destructured params of `createWorker` (line 91). The updated signature:

```typescript
export function createWorker({
  chain,
  store,
  infoAgents,
  judgeAgents,
  ipfs,
  pollIntervalMs = 5_000,
  logger = console,
  now = () => BigInt(Math.floor(Date.now() / 1_000)),
  createNonce = createRandomNonce,
}: WorkerConfig) {
```

- [ ] **Step 2: Update `handleCommitting` to upload to IPFS**

In `handleCommitting`, replace **only line 142** (`const answer = encodeInfoAgentResult(result);`). Leave lines 143-144 (`const nonce = createNonce()` and `const commitment = computeCommitment(answer, nonce)`) intact:

```typescript
// Current (line 142 only):
const answer = encodeInfoAgentResult(result);

// Replace with:
const cid = await ipfs.upload(result);
logger.info(`[req=${context.requestId}] Agent ${agent.address} uploaded answer to IPFS: ${cid}`);
const answer = stringToHex(cid);
```

Lines 143-144 remain unchanged — `nonce` and `commitment` still work because `answer` is now the CID hex instead of the encoded JSON hex.

Add `stringToHex` to the viem import at the top of the file (it's not currently imported there).

Remove the `encodeInfoAgentResult` import since it's no longer used:

```typescript
// Remove from imports:
import { decodeInfoAgentResult, encodeInfoAgentResult } from './infoAgent.js';
// Replace with:
import { parseInfoAgentResult } from './infoAgent.js';
```

- [ ] **Step 3: Replace `decodeAnswer` with async `resolveAnswer`**

**Two changes:**

**A.** Delete the existing `decodeAnswer` function at module scope (lines 55-71 of `worker.ts`, which is *outside* `createWorker`).

**B.** Add the new `resolveAnswer` function *inside* `createWorker` — place it as the first function after the opening brace of `createWorker` (after line 100, before `maybeAdvancePhase`). It must be inside `createWorker` because it references `ipfs` from the closure:

```typescript
  async function resolveAnswer(answerHex: Hex): Promise<DecodedInfoAnswer> {
    const cidOrJson = hexToString(answerHex);

    // Detect IPFS CID (CIDv0 or CIDv1) vs raw JSON
    if (cidOrJson.startsWith('Qm') || cidOrJson.startsWith('bafy')) {
      const content = await ipfs.fetch(cidOrJson);
      const parsedAnswer = parseInfoAgentResult(content);
      return {
        rawAnswer: answerHex,
        parsedAnswer,
        text: JSON.stringify(parsedAnswer),
      };
    }

    // Fallback: treat as raw JSON (backward compat)
    try {
      const parsedAnswer = parseInfoAgentResult(JSON.parse(cidOrJson));
      return {
        rawAnswer: answerHex,
        parsedAnswer,
        text: JSON.stringify(parsedAnswer),
      };
    } catch {
      return {
        rawAnswer: answerHex,
        parsedAnswer: null,
        text: cidOrJson,
      };
    }
  }
```

- [ ] **Step 4: Update `handleJudging` to use `resolveAnswer` and upload judge outputs**

In `handleJudging`, replace the sync map (lines 228-231):

```typescript
// Current:
const revealedAnswers = context.revealedAgents.map((agentAddress, index) => ({
  agentAddress,
  answer: decodeAnswer(context.revealedAnswers[index] ?? '0x'),
}));
```

With async parallel fetch:

```typescript
const revealedAnswers = await Promise.all(
  context.revealedAgents.map(async (agentAddress, index) => ({
    agentAddress,
    answer: await resolveAnswer(context.revealedAnswers[index] ?? '0x'),
  })),
);
```

Then replace the judge output encoding and aggregate call (lines 243-252):

```typescript
// Current:
const encoded = encodeJudgeDecision(decision);
await chain.aggregate(
  judge.address,
  context.requestId,
  encoded.finalAnswer,
  decision.winnerAddresses,
  encoded.reasoning,
);
```

With IPFS upload:

```typescript
const [finalAnswerCid, reasoningCid] = await Promise.all([
  ipfs.upload({ content: decision.finalAnswer }),
  ipfs.upload({ content: decision.reasoning }),
]);
logger.info(`[req=${context.requestId}] Judge uploaded to IPFS: finalAnswer=${finalAnswerCid}, reasoning=${reasoningCid}`);

await chain.aggregate(
  judge.address,
  context.requestId,
  stringToHex(finalAnswerCid),
  decision.winnerAddresses,
  stringToHex(reasoningCid),
);
```

Remove the `encodeJudgeDecision` import since it's no longer used:

```typescript
// Remove from imports:
import { encodeJudgeDecision, validateJudgeDecision } from './judgeAgent.js';
// Replace with:
import { validateJudgeDecision } from './judgeAgent.js';
```

- [ ] **Step 5: Run all tests**

Run: `cd client && npx vitest run`
Expected: All tests pass. The worker is only tested indirectly via `index.test.ts` (which just checks the shape), so no worker tests should break.

- [ ] **Step 6: Commit**

```bash
git add client/src/worker.ts
git commit -m "feat: integrate IPFS upload/fetch into worker commit and judge paths"
```

---

### Task 4: Wire IpfsService into runtime

**Files:**
- Modify: `client/src/runtime.ts`

- [ ] **Step 1: Create IpfsService and pass to worker**

In `client/src/runtime.ts`, add import:

```typescript
import { createIpfsService } from './ipfs.js';
```

Before the `const worker = createWorker({...})` call (line 111), create the IPFS service:

```typescript
const ipfs = createIpfsService({
  pinataJwt: config.pinataJwt,
  gatewayUrl: config.ipfsGatewayUrl,
});
```

Add `ipfs` to the `createWorker` call:

```typescript
const worker = createWorker({
  chain: chainClient,
  store,
  infoAgents,
  judgeAgents,
  ipfs,
  pollIntervalMs: config.pollIntervalMs,
});
```

- [ ] **Step 2: Verify build compiles**

Run: `cd client && npx tsc --noEmit`
Expected: No type errors

- [ ] **Step 3: Commit**

```bash
git add client/src/runtime.ts
git commit -m "feat: wire IpfsService into runtime"
```

---

## Chunk 4: Web UI Update

### Task 5: Update web UI to resolve IPFS CIDs

**Files:**
- Modify: `web/index.html`

- [ ] **Step 1: Add IPFS gateway constant**

Near the top of the `<script>` section in `web/index.html`, add:

```javascript
const IPFS_GATEWAY_URL = 'https://magenta-tremendous-cockroach-62.mypinata.cloud';
```

- [ ] **Step 2: Replace `tryDecodeHex` with async `tryDecodeHex`**

Replace the existing `tryDecodeHex` function (lines 1685-1696) with:

```javascript
async function tryDecodeHex(hex) {
  if (!hex || hex === '0x') return null;
  try {
    const text = ethers.toUtf8String(hex);
    // Detect IPFS CID
    if (text.startsWith('Qm') || text.startsWith('bafy')) {
      try {
        const response = await fetch(`${IPFS_GATEWAY_URL}/ipfs/${text}`);
        if (!response.ok) return { text };
        const data = await response.json();
        // Handle { content: "..." } envelope from judge outputs
        if (data && typeof data.content === 'string' && Object.keys(data).length === 1) {
          return { text: data.content };
        }
        return data;
      } catch {
        return { text };
      }
    }
    try {
      return JSON.parse(text);
    } catch {
      return { text };
    }
  } catch {
    return null;
  }
}
```

- [ ] **Step 3: Make `renderRequests` async and update all callers of `tryDecodeHex`**

The `renderRequests` function (line 1787) is currently sync. It builds HTML via `container.innerHTML = sorted.map(...)`. Since `tryDecodeHex` is now async, the entire rendering pipeline must be made async. Here's the full structural change:

**A. Change `renderRequests` signature to async:**

```javascript
// Line 1787: change from:
function renderRequests(requests) {
// To:
async function renderRequests(requests) {
```

**B. Change `sorted.map(...)` to async `Promise.all`:**

The outer `container.innerHTML = sorted.map((r, idx) => { ... }).join('')` (line 1832) must become:

```javascript
const cards = await Promise.all(sorted.map(async (r, idx) => {
  // ... all existing card rendering code, now with await on tryDecodeHex calls
```

And close with:

```javascript
}));
container.innerHTML = cards.join('');
```

**C. Inside the async map callback, add `await` to the 3 `tryDecodeHex` call sites:**

Line 1845 (answer cards — this inner `.map` also becomes async):
```javascript
const answerCards = (await Promise.all(r.revealedAgents.map(async (agent, i) => {
  const decoded = await tryDecodeHex(r.revealedAnswers[i]);
  // ... rest of card rendering stays the same, return the HTML string
}))).join('');
```

Line 1873:
```javascript
const decoded = await tryDecodeHex(r.finalAnswer);
```

Line 1875:
```javascript
const reasoningDecoded = r.reasoning ? await tryDecodeHex(r.reasoning) : null;
```

**D. Update callers of `renderRequests` to use `await`:**

Search for all calls to `renderRequests(...)` in the file and add `await` before each one. The containing function (likely a polling/update function) must also be marked `async` if not already.

- [ ] **Step 4: Test manually by opening `web/index.html` in browser**

Verify the page loads without JavaScript errors in the console. Existing raw JSON hex data (if any) should still decode and display correctly.

- [ ] **Step 5: Commit**

```bash
git add web/index.html
git commit -m "feat: update web UI to resolve IPFS CIDs from on-chain data"
```

---

## Chunk 5: Final Verification

### Task 6: End-to-end verification and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run full test suite**

Run: `cd client && npx vitest run`
Expected: All tests pass

- [ ] **Step 2: Verify TypeScript compilation**

Run: `cd client && npx tsc --noEmit`
Expected: No type errors

- [ ] **Step 3: Verify build**

Run: `cd client && npm run build`
Expected: Clean build, dist/ output generated

- [ ] **Step 4: Final commit (if any cleanup needed)**

Only if there are unstaged changes from cleanup.
