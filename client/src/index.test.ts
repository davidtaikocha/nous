import { describe, expect, it } from 'vitest';

import { createNousClient } from './index.js';

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
