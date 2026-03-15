import { describe, expect, it } from 'vitest';

import { buildRuntime } from './runtime.js';

describe('buildRuntime', () => {
  it('creates agent runtimes for all configured wallets', () => {
    const runtime = buildRuntime({
      config: {
        rpcUrl: 'http://127.0.0.1:8545',
        oracleAddress: '0x0000000000000000000000000000000000000001',
        chainId: 167,
        modelId: 'gpt-4.1-mini',
        openRouterApiKey: 'test-key',
        pollIntervalMs: 5_000,
        stateFile: '/tmp/nous-agent-state.json',
        infoAgentPrivateKeys: [`0x${'11'.repeat(32)}`],
        judgeAgentPrivateKeys: [`0x${'22'.repeat(32)}`],
      },
    });

    expect(runtime.infoAgents).toHaveLength(1);
    expect(runtime.judgeAgents).toHaveLength(1);
  });
});
