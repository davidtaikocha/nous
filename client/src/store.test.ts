import { describe, expect, it } from 'vitest';

import { createMemoryStateStore } from './store.js';

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
