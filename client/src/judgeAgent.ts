import { OpenRouter } from '@openrouter/sdk';
import { getAddress, stringToHex, type Address } from 'viem';
import { z } from 'zod';

import type { DecodedInfoAnswer, JudgeDecision, OracleRequest } from './types.js';

export const judgeDecisionSchema = z.object({
  finalAnswer: z.string().min(1),
  reasoning: z.string().min(1),
  winnerAddresses: z.array(z.string()).default([]),
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
  // If no winners selected, default to all revealed agents
  if (decision.winnerAddresses.length === 0) {
    decision = { ...decision, winnerAddresses: revealedAddresses };
  }

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
    'Your job is to evaluate revealed answers and select the best one(s).',
    `Question: ${request.query}`,
    `Specifications: ${request.specifications || 'No additional specifications provided.'}`,
    'Instructions:',
    '- You MUST select at least one winner. The winnerAddresses array must NOT be empty.',
    '- If all answers are weak, pick the least bad one as winner.',
    '- Evaluate factual accuracy first, source quality second, and completeness third.',
    '- Multiple winners are allowed when answers are equivalent in quality.',
    '- Synthesize the best answer into finalAnswer.',
    '- In reasoning, explain your decision.',
    'Return a JSON object with: finalAnswer (string), reasoning (string), winnerAddresses (array of address strings, at least one).',
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

function sanitizeLlmJson(raw: string): string {
  // Strip markdown code fences
  let text = raw.replace(/^```(?:json)?\s*\n?/i, '').replace(/\n?```\s*$/i, '').trim();
  // Escape control characters only inside JSON string values (between quotes)
  text = text.replace(/"(?:[^"\\]|\\.)*"/g, (match) =>
    match.replace(/[\x00-\x1F\x7F]/g, (ch) => {
      if (ch === '\n') return '\\n';
      if (ch === '\r') return '\\r';
      if (ch === '\t') return '\\t';
      return '';
    }),
  );
  return text;
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
      plugins: [{ id: 'web', max_results: 5 }],
      messages: [
        {
          role: 'system',
          content: 'You have web search access. Use it to verify the accuracy of revealed answers. Return only a valid JSON object matching the requested schema.',
        },
        {
          role: 'user',
          content: buildJudgePrompt({ request, revealedAnswers }),
        },
      ],
    } as any,
  });
  const content = response.choices[0]?.message?.content;
  const rawText = extractAssistantText(content);
  const cleanedText = sanitizeLlmJson(rawText);
  const parsed = JSON.parse(cleanedText) as unknown;

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
