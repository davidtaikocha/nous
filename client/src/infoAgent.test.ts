import { describe, expect, it } from 'vitest';

import { buildInfoAgentPrompt, decodeInfoAgentResult, encodeInfoAgentResult, parseInfoAgentResult } from './infoAgent.js';

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

describe('info agent encoding', () => {
  it('round-trips structured answers through hex encoding', () => {
    const encoded = encodeInfoAgentResult({
      answer: 'Yes',
      confidence: 0.75,
      reasoning: 'Reasoning',
      sources: ['https://example.com'],
    });

    expect(decodeInfoAgentResult(encoded)?.answer).toBe('Yes');
  });
});

describe('buildInfoAgentPrompt', () => {
  it('instructs the agent to abstain when evidence is weak', () => {
    const prompt = buildInfoAgentPrompt({
      requester: '0x0000000000000000000000000000000000000001',
      rewardAmount: 0n,
      rewardToken: '0x0000000000000000000000000000000000000000',
      bondAmount: 0n,
      bondToken: '0x0000000000000000000000000000000000000000',
      numInfoAgents: 1n,
      deadline: 0n,
      query: 'Did company X file for bankruptcy?',
      specifications: '',
      requiredCapabilities: { capabilities: [], domains: [] },
    });

    expect(prompt).toMatch(/abstain/i);
    expect(prompt).toMatch(/weak or conflicting evidence/i);
    expect(prompt).toMatch(/never invent/i);
  });
});
