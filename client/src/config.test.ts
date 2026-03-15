import { describe, expect, it } from 'vitest';

import { loadConfig } from './config.js';

describe('loadConfig', () => {
  it('parses info and judge private keys from env-style input', () => {
    const config = loadConfig({
      RPC_URL: 'http://127.0.0.1:8545',
      ORACLE_ADDRESS: '0x0000000000000000000000000000000000000001',
      CHAIN_ID: '167',
      INFO_AGENT_PRIVATE_KEYS: `0x${'11'.repeat(32)},0x${'22'.repeat(32)}`,
      JUDGE_AGENT_PRIVATE_KEYS: `0x${'33'.repeat(32)}`,
      MODEL_ID: 'openai/gpt-4.1-mini',
      OPENROUTER_API_KEY: 'test-key',
    });

    expect(config.infoAgentPrivateKeys).toHaveLength(2);
    expect(config.judgeAgentPrivateKeys).toHaveLength(1);
    expect(config.chainId).toBe(167);
    expect(config.openRouterApiKey).toBe('test-key');
  });
});
