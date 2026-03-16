import { describe, expect, it, vi } from 'vitest';

import { createMemoryStateStore } from './store.js';
import { createWorker } from './worker.js';

describe('worker', () => {
  it('reveals a persisted answer when a request enters reveal phase', async () => {
    const submitReveal = vi.fn(async () => '0xdeadbeef' as const);
    const store = createMemoryStateStore();

    await store.saveCommit({
      requestId: 5n,
      agentAddress: '0x0000000000000000000000000000000000000001',
      answer: '0x1234',
      nonce: '42',
      commitment: '0xabcd',
    });

    const worker = createWorker({
      chain: {
        listActiveRequestIds: async () => [5n],
        getRequestContext: async () => ({
          requestId: 5n,
          phase: 'revealing' as const,
          request: {
            requester: '0x0000000000000000000000000000000000000009',
            rewardAmount: 0n,
            rewardToken: '0x0000000000000000000000000000000000000000',
            bondAmount: 0n,
            bondToken: '0x0000000000000000000000000000000000000000',
            numInfoAgents: 1n,
            deadline: 0n,
            query: 'test',
            specifications: '',
            requiredCapabilities: { capabilities: [], domains: [] },
          },
          committedAgents: ['0x0000000000000000000000000000000000000001'],
          commitHashes: [],
          revealedAgents: [],
          revealedAnswers: [],
          selectedJudge: '0x0000000000000000000000000000000000000009',
          revealDeadline: 9999999999n,
          finalized: false,
          finalAnswer: '0x',
        }),
        reveal: submitReveal,
        commit: vi.fn(async () => '0xcommit' as const),
        aggregate: vi.fn(async () => '0xaggregate' as const),
        endCommitPhase: vi.fn(async () => '0xendcommit' as const),
        endRevealPhase: vi.fn(async () => '0xendreveal' as const),
      } as never,
      store,
      infoAgents: [
        {
          address: '0x0000000000000000000000000000000000000001',
          generate: vi.fn(),
        },
      ],
      judgeAgents: [],
      ipfs: { upload: vi.fn(), fetch: vi.fn() },
      logger: {
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn(),
      },
    });

    await worker.tick();

    expect(submitReveal).toHaveBeenCalledTimes(1);
  });
});
