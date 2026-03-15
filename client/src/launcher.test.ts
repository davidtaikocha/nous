import { describe, expect, it } from 'vitest';

import { buildAgentConfigs, parseAgentManifest } from './launcher.js';

describe('parseAgentManifest', () => {
  it('parses manifest entries for info and judge agents', () => {
    const manifest = parseAgentManifest({
      agents: [
        {
          id: 'info-1',
          role: 'info',
          model: 'openai/gpt-4.1-mini',
          privateKey: `0x${'11'.repeat(32)}`,
        },
        {
          id: 'judge-1',
          role: 'judge',
          model: 'anthropic/claude-3.7-sonnet',
          privateKey: `0x${'22'.repeat(32)}`,
        },
      ],
    });

    expect(manifest.agents).toHaveLength(2);
    expect(manifest.agents[1]?.role).toBe('judge');
  });
});

describe('buildAgentConfigs', () => {
  it('builds one client config per manifest agent with role-specific keys and models', () => {
    const configs = buildAgentConfigs({
      manifest: parseAgentManifest({
        agents: [
          {
            id: 'info-1',
            role: 'info',
            model: 'openai/gpt-4.1-mini',
            privateKey: `0x${'11'.repeat(32)}`,
          },
          {
            id: 'judge-1',
            role: 'judge',
            model: 'anthropic/claude-3.7-sonnet',
            privateKey: `0x${'22'.repeat(32)}`,
          },
        ],
      }),
      baseConfig: {
        rpcUrl: 'http://127.0.0.1:8545',
        oracleAddress: '0x0000000000000000000000000000000000000001',
        chainId: 167,
        modelId: 'unused-default',
        openRouterApiKey: 'test-key',
        pollIntervalMs: 5_000,
        stateFile: '/tmp/unused.json',
        infoAgentPrivateKeys: [],
        judgeAgentPrivateKeys: [],
      },
      stateDir: '/tmp/nous-state',
    });

    expect(configs).toHaveLength(2);
    expect(configs[0]?.config.modelId).toBe('openai/gpt-4.1-mini');
    expect(configs[0]?.config.infoAgentPrivateKeys).toHaveLength(1);
    expect(configs[0]?.config.judgeAgentPrivateKeys).toHaveLength(0);
    expect(configs[0]?.config.stateFile).toContain('/tmp/nous-state/info-1.json');
    expect(configs[1]?.config.modelId).toBe('anthropic/claude-3.7-sonnet');
    expect(configs[1]?.config.infoAgentPrivateKeys).toHaveLength(0);
    expect(configs[1]?.config.judgeAgentPrivateKeys).toHaveLength(1);
  });

  it('throws when a manifest private key is malformed', () => {
    expect(() =>
      parseAgentManifest({
        agents: [
          {
            id: 'info-1',
            role: 'info',
            model: 'openai/gpt-4.1-mini',
            privateKey: 'not-a-key',
          },
        ],
      }),
    ).toThrow(/private key/i);
  });
});
