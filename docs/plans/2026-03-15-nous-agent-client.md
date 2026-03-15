# Nous Agent Client Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a TypeScript package in `client/` that runs info-agent and judge-agent workflows against `NousOracle`, including onchain `commit`, `reveal`, and `aggregate` transactions.

**Architecture:** The client is a Node worker with a reusable chain layer, role-specific agent runners, and a small persistent store for commit-reveal state. `viem` handles contract interaction, the Vercel AI SDK handles model generation, and tests exercise the worker logic with mocked chain and model boundaries.

**Tech Stack:** TypeScript, Node.js, Vitest, viem, Vercel AI SDK, zod

---

### Task 1: Scaffold the client package

**Files:**
- Create: `client/package.json`
- Create: `client/tsconfig.json`
- Create: `client/vitest.config.ts`
- Create: `client/.gitignore`
- Create: `client/src/index.ts`
- Create: `client/src/cli.ts`

**Step 1: Write the failing test**

Create `client/src/index.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { createNousClient } from './index';

describe('createNousClient', () => {
  it('creates a client object with worker entrypoints', () => {
    const client = createNousClient({} as never);

    expect(client).toMatchObject({
      runWorker: expect.any(Function),
      runInfoAgentOnce: expect.any(Function),
      runJudgeOnce: expect.any(Function),
    });
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/index.test.ts`
Expected: FAIL because package files and exports do not exist yet

**Step 3: Write minimal implementation**

- Add package metadata, scripts, and dependencies
- Add a minimal TypeScript config and Vitest config
- Export a `createNousClient` function that returns stubbed async methods
- Add a CLI placeholder that can be executed later

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/index.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/package.json client/tsconfig.json client/vitest.config.ts client/.gitignore client/src/index.ts client/src/cli.ts client/src/index.test.ts
git commit -m "feat: scaffold nous agent client package"
```

### Task 2: Add configuration parsing and validation

**Files:**
- Create: `client/src/config.ts`
- Create: `client/src/config.test.ts`
- Modify: `client/src/index.ts`
- Modify: `client/src/cli.ts`

**Step 1: Write the failing test**

Create `client/src/config.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { loadConfig } from './config';

describe('loadConfig', () => {
  it('parses info and judge private keys from env-style input', () => {
    const config = loadConfig({
      RPC_URL: 'http://127.0.0.1:8545',
      ORACLE_ADDRESS: '0x0000000000000000000000000000000000000001',
      CHAIN_ID: '167',
      INFO_AGENT_PRIVATE_KEYS: '0x11,0x22',
      JUDGE_AGENT_PRIVATE_KEYS: '0x33',
      MODEL_ID: 'openai/gpt-4.1-mini',
    });

    expect(config.infoAgentPrivateKeys).toHaveLength(2);
    expect(config.judgeAgentPrivateKeys).toHaveLength(1);
    expect(config.chainId).toBe(167);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/config.test.ts`
Expected: FAIL because `loadConfig` does not exist

**Step 3: Write minimal implementation**

- Add a `zod`-backed config parser
- Normalize comma-separated private key lists
- Add defaults for poll interval and state file path
- Wire the CLI to load configuration from `process.env`

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/config.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/config.ts client/src/config.test.ts client/src/index.ts client/src/cli.ts
git commit -m "feat: add client configuration parsing"
```

### Task 3: Implement the commit-reveal persistence store

**Files:**
- Create: `client/src/store.ts`
- Create: `client/src/store.test.ts`

**Step 1: Write the failing test**

Create `client/src/store.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { createMemoryStateStore } from './store';

describe('state store', () => {
  it('persists and retrieves reveal material by request and wallet', async () => {
    const store = createMemoryStateStore();

    await store.saveCommit({
      requestId: 7n,
      agentAddress: '0x0000000000000000000000000000000000000007',
      answer: '0x1234',
      nonce: '99',
      commitment: '0xabcd',
    });

    await expect(
      store.getCommit(7n, '0x0000000000000000000000000000000000000007'),
    ).resolves.toMatchObject({ nonce: '99', answer: '0x1234' });
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/store.test.ts`
Expected: FAIL because the store module does not exist

**Step 3: Write minimal implementation**

- Define store interfaces
- Implement an in-memory store for tests
- Implement a file-backed JSON store for runtime use
- Support commit persistence and reveal-submitted updates

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/store.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/store.ts client/src/store.test.ts
git commit -m "feat: add commit reveal state store"
```

### Task 4: Implement contract ABI and chain helpers

**Files:**
- Create: `client/src/oracleAbi.ts`
- Create: `client/src/chain.ts`
- Create: `client/src/chain.test.ts`

**Step 1: Write the failing test**

Create `client/src/chain.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { computeCommitment } from './chain';

describe('computeCommitment', () => {
  it('hashes encoded answer bytes with the nonce', () => {
    const commitment = computeCommitment('0x1234', 42n);

    expect(commitment).toMatch(/^0x[a-f0-9]{64}$/);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/chain.test.ts`
Expected: FAIL because chain helpers do not exist

**Step 3: Write minimal implementation**

- Add the minimal `NousOracle` ABI needed by the client
- Implement commitment hashing with `encodeAbiParameters` and `keccak256`
- Add request/phase read helpers and transaction helper signatures

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/chain.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/oracleAbi.ts client/src/chain.ts client/src/chain.test.ts
git commit -m "feat: add oracle chain helpers"
```

### Task 5: Implement info-agent output generation and validation

**Files:**
- Create: `client/src/infoAgent.ts`
- Create: `client/src/infoAgent.test.ts`

**Step 1: Write the failing test**

Create `client/src/infoAgent.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { parseInfoAgentResult } from './infoAgent';

describe('parseInfoAgentResult', () => {
  it('accepts valid structured info-agent output', () => {
    const result = parseInfoAgentResult({
      answer: 'Company X filed for bankruptcy',
      confidence: 0.82,
      reasoning: 'Two reliable sources confirm it.',
      sources: ['https://example.com/news'],
    });

    expect(result.confidence).toBe(0.82);
    expect(result.sources[0]).toContain('https://');
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/infoAgent.test.ts`
Expected: FAIL because the parser does not exist

**Step 3: Write minimal implementation**

- Define a schema for valid info-agent output
- Implement prompt builder and output parser
- Add encoder to serialize the normalized answer as hex bytes for onchain reveal

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/infoAgent.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/infoAgent.ts client/src/infoAgent.test.ts
git commit -m "feat: add info agent output handling"
```

### Task 6: Implement judge-agent output generation and winner validation

**Files:**
- Create: `client/src/judgeAgent.ts`
- Create: `client/src/judgeAgent.test.ts`

**Step 1: Write the failing test**

Create `client/src/judgeAgent.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { validateJudgeDecision } from './judgeAgent';

describe('validateJudgeDecision', () => {
  it('rejects winners that did not reveal', () => {
    expect(() =>
      validateJudgeDecision(
        {
          finalAnswer: 'Yes',
          reasoning: 'Consensus favored yes',
          winnerAddresses: ['0x0000000000000000000000000000000000000002'],
        },
        ['0x0000000000000000000000000000000000000001'],
      ),
    ).toThrow(/winner/i);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/judgeAgent.test.ts`
Expected: FAIL because the judge module does not exist

**Step 3: Write minimal implementation**

- Define the judge decision schema
- Build a prompt formatter for revealed answers
- Validate that all winners are part of the revealed set
- Add encoder for final answer and reasoning bytes

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/judgeAgent.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/judgeAgent.ts client/src/judgeAgent.test.ts
git commit -m "feat: add judge agent decision handling"
```

### Task 7: Implement the worker orchestration logic

**Files:**
- Create: `client/src/worker.ts`
- Create: `client/src/worker.test.ts`
- Modify: `client/src/index.ts`

**Step 1: Write the failing test**

Create `client/src/worker.test.ts` with:

```ts
import { describe, expect, it, vi } from 'vitest';
import { createWorker } from './worker';

describe('worker', () => {
  it('reveals a persisted answer when a request enters reveal phase', async () => {
    const submitReveal = vi.fn();
    const worker = createWorker({
      chain: {
        listActiveRequestIds: async () => [5n],
        getRequestContext: async () => ({
          requestId: 5n,
          phase: 'revealing',
          selectedJudge: '0x0000000000000000000000000000000000000009',
          revealedAgents: [],
          committedAgents: ['0x0000000000000000000000000000000000000001'],
        }),
        reveal: submitReveal,
      },
      store: {
        getCommit: async () => ({
          requestId: 5n,
          agentAddress: '0x0000000000000000000000000000000000000001',
          answer: '0x1234',
          nonce: '42',
        }),
      },
      infoAgents: ['0x0000000000000000000000000000000000000001'],
      judgeAgents: [],
    } as never);

    await worker.tick();

    expect(submitReveal).toHaveBeenCalledTimes(1);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/worker.test.ts`
Expected: FAIL because the worker does not exist

**Step 3: Write minimal implementation**

- Implement a worker `tick()` that inspects request state
- Add commit, reveal, and aggregate action selection
- Use the store for reveal recovery
- Expose `runWorker`, `runInfoAgentOnce`, and `runJudgeOnce`

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/worker.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/worker.ts client/src/worker.test.ts client/src/index.ts
git commit -m "feat: add nous worker orchestration"
```

### Task 8: Wire the real AI SDK and contract client into the runtime

**Files:**
- Create: `client/src/runtime.ts`
- Create: `client/src/runtime.test.ts`
- Modify: `client/src/chain.ts`
- Modify: `client/src/infoAgent.ts`
- Modify: `client/src/judgeAgent.ts`
- Modify: `client/src/cli.ts`

**Step 1: Write the failing test**

Create `client/src/runtime.test.ts` with:

```ts
import { describe, expect, it } from 'vitest';
import { buildRuntime } from './runtime';

describe('buildRuntime', () => {
  it('creates agent runtimes for all configured wallets', () => {
    const runtime = buildRuntime({
      config: {
        infoAgentPrivateKeys: ['0x11'],
        judgeAgentPrivateKeys: ['0x22'],
      },
    } as never);

    expect(runtime.infoAgents).toHaveLength(1);
    expect(runtime.judgeAgents).toHaveLength(1);
  });
});
```

**Step 2: Run test to verify it fails**

Run: `cd client && npm test -- --run src/runtime.test.ts`
Expected: FAIL because runtime composition does not exist

**Step 3: Write minimal implementation**

- Build wallet clients from private keys
- Build model call wrappers using the AI SDK
- Compose the chain client, store, worker, and role runners for CLI execution

**Step 4: Run test to verify it passes**

Run: `cd client && npm test -- --run src/runtime.test.ts`
Expected: PASS

**Step 5: Commit**

```bash
git add client/src/runtime.ts client/src/runtime.test.ts client/src/chain.ts client/src/infoAgent.ts client/src/judgeAgent.ts client/src/cli.ts
git commit -m "feat: connect ai sdk and chain runtime"
```

### Task 9: Add operator documentation and full-package verification

**Files:**
- Create: `client/README.md`
- Modify: `README.md`

**Step 1: Write the failing test**

No new unit test. This task is verification and documentation.

**Step 2: Run test to verify current package behavior**

Run: `cd client && npm test -- --run`
Expected: PASS for all client tests

**Step 3: Write minimal implementation**

- Document required environment variables
- Document worker and one-shot commands
- Add a short repo-level note pointing to `client/README.md`

**Step 4: Run verification**

Run: `cd client && npm test -- --run && npm run build`
Expected: PASS

**Step 5: Commit**

```bash
git add client/README.md README.md
git commit -m "docs: document nous agent client usage"
```
