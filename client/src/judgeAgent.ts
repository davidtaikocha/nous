import { OpenRouter } from '@openrouter/sdk';
import { getAddress, stringToHex, type Address } from 'viem';
import { z } from 'zod';

import type { DecodedInfoAnswer, JudgeDecision, OracleRequest } from './types.js';

export const judgeDecisionSchema = z.object({
  finalAnswer: z.string().min(1),
  reasoning: z.string().min(1),
  winnerAddresses: z.array(z.string()).min(1),
});

export function parseJudgeDecision(input: unknown): JudgeDecision {
  const parsed = judgeDecisionSchema.parse(input);
  return {
    finalAnswer: parsed.finalAnswer,
    reasoning: parsed.reasoning,
    winnerAddresses: parsed.winnerAddresses.map((address) => getAddress(address)),
  };
}

export function validateJudgeDecision(
  decision: JudgeDecision,
  revealedAddresses: Address[],
): JudgeDecision {
  const revealedSet = new Set(revealedAddresses.map((address) => getAddress(address).toLowerCase()));

  for (const winner of decision.winnerAddresses) {
    if (!revealedSet.has(getAddress(winner).toLowerCase())) {
      throw new Error(`Judge selected a winner that did not reveal: ${winner}`);
    }
  }

  return decision;
}

export function buildJudgePrompt({
  request,
  revealedAnswers,
}: {
  request: OracleRequest;
  revealedAnswers: Array<{ agentAddress: Address; answer: DecodedInfoAnswer }>;
}): string {
  return [
    'You are the judge agent for an oracle council.',
    'Your job is to select the revealed answers that are best supported by evidence, not the answers that sound most polished.',
    `Question: ${request.query}`,
    `Specifications: ${request.specifications || 'No additional specifications provided.'}`,
    'Instructions:',
    '- Evaluate factual accuracy first, source quality second, and completeness third.',
    '- Ignore eloquence, verbosity, and writing style.',
    '- Prefer a well-supported abstention over an unsupported claim.',
    '- Penalize answers that overclaim certainty, ignore conflicting evidence, or cite weak support.',
    '- Multiple winners are allowed when several revealed answers are materially equivalent in correctness and evidence quality.',
    '- In reasoning, explain why the winners beat the losers.',
    'Return finalAnswer, reasoning, and winnerAddresses.',
    'Revealed answers:',
    ...revealedAnswers.map(({ agentAddress, answer }) => {
      if (answer.parsedAnswer) {
        return `${agentAddress}: ${JSON.stringify(answer.parsedAnswer)}`;
      }

      return `${agentAddress}: ${answer.text}`;
    }),
  ].join('\n');
}

function extractAssistantText(content: unknown): string {
  if (typeof content === 'string') {
    return content;
  }

  if (Array.isArray(content)) {
    return content
      .map((item) => {
        if (typeof item === 'string') {
          return item;
        }
        if (
          item &&
          typeof item === 'object' &&
          'type' in item &&
          (item as { type?: unknown }).type === 'text' &&
          'text' in item &&
          typeof (item as { text?: unknown }).text === 'string'
        ) {
          return (item as { text: string }).text;
        }

        return '';
      })
      .filter(Boolean)
      .join('\n');
  }

  throw new Error('OpenRouter returned an unsupported assistant message content shape');
}

export async function generateJudgeDecision({
  openRouter,
  model,
  request,
  revealedAnswers,
}: {
  openRouter: OpenRouter;
  model: string;
  request: OracleRequest;
  revealedAnswers: Array<{ agentAddress: Address; answer: DecodedInfoAnswer }>;
}): Promise<JudgeDecision> {
  const response = await openRouter.chat.send({
    chatGenerationParams: {
      model,
      stream: false,
      temperature: 0,
      topP: 1,
      responseFormat: {
        type: 'json_object',
      },
      messages: [
        {
          role: 'system',
          content: 'Return only a valid JSON object matching the requested schema.',
        },
        {
          role: 'user',
          content: buildJudgePrompt({ request, revealedAnswers }),
        },
      ],
    },
  });
  const content = response.choices[0]?.message?.content;
  const rawText = extractAssistantText(content);
  const parsed = JSON.parse(rawText) as unknown;

  return parseJudgeDecision(parsed);
}

export function encodeJudgeDecision(decision: JudgeDecision): {
  finalAnswer: `0x${string}`;
  reasoning: `0x${string}`;
} {
  return {
    finalAnswer: stringToHex(decision.finalAnswer),
    reasoning: stringToHex(decision.reasoning),
  };
}
