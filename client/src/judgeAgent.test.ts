import { describe, expect, it } from 'vitest';

import { buildJudgePrompt, encodeJudgeDecision, validateJudgeDecision } from './judgeAgent.js';

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

describe('encodeJudgeDecision', () => {
  it('encodes final answer and reasoning as hex bytes', () => {
    const encoded = encodeJudgeDecision({
      finalAnswer: 'Yes',
      reasoning: 'Consistent evidence',
      winnerAddresses: ['0x0000000000000000000000000000000000000001'],
    });

    expect(encoded.finalAnswer).toMatch(/^0x/);
    expect(encoded.reasoning).toMatch(/^0x/);
  });
});

describe('buildJudgePrompt', () => {
  it('tells the judge to prefer supported abstentions over unsupported claims', () => {
    const prompt = buildJudgePrompt({
      request: {
        requester: '0x0000000000000000000000000000000000000001',
        rewardAmount: 0n,
        rewardToken: '0x0000000000000000000000000000000000000000',
        bondAmount: 0n,
        bondToken: '0x0000000000000000000000000000000000000000',
        numInfoAgents: 2n,
        deadline: 0n,
        query: 'Did company X file for bankruptcy?',
        specifications: '',
        requiredCapabilities: { capabilities: [], domains: [] },
      },
      revealedAnswers: [
        {
          agentAddress: '0x0000000000000000000000000000000000000002',
          answer: {
            rawAnswer: '0x',
            parsedAnswer: null,
            text: 'insufficient evidence',
          },
        },
      ],
    });

    expect(prompt).toMatch(/prefer a well-supported abstention/i);
    expect(prompt).toMatch(/factual accuracy first/i);
    expect(prompt).toMatch(/ignore eloquence/i);
  });
});
