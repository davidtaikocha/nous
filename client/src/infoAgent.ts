import { OpenRouter } from '@openrouter/sdk';
import { hexToString, stringToHex } from 'viem';
import { z } from 'zod';

import type { InfoAgentResult, OracleRequest } from './types.js';

export const infoAgentResultSchema = z.object({
  answer: z.string().min(1),
  confidence: z.number().min(0).max(1),
  reasoning: z.string().min(1),
  sources: z.array(z.string().url()).default([]),
});

export function parseInfoAgentResult(input: unknown): InfoAgentResult {
  return infoAgentResultSchema.parse(input);
}

export function buildInfoAgentPrompt(request: OracleRequest): string {
  const capabilities = request.requiredCapabilities.capabilities.join(', ') || 'none';
  const domains = request.requiredCapabilities.domains.join(', ') || 'none';
  const specifications = request.specifications || 'No additional specifications provided.';

  return [
    'You are an info agent participating in an oracle council.',
    'Your job is to provide an answer only when it is supported by sufficiently strong evidence.',
    `Question: ${request.query}`,
    `Specifications: ${specifications}`,
    `Required capabilities: ${capabilities}`,
    `Required domains: ${domains}`,
    'Instructions:',
    '- Answer with verified facts, not guesses.',
    '- Separate observed facts from inference in your reasoning.',
    '- Prefer primary sources and recent sources when the question is time-sensitive.',
    '- If you have weak or conflicting evidence, abstain instead of guessing.',
    '- If you abstain, say so clearly in the answer field and explain why in reasoning.',
    '- Never invent facts, dates, URLs, or certainty.',
    '- Never invent sources. Only include sources you actually relied on.',
    '- Use lower confidence when evidence is partial, indirect, or stale.',
    'Return a JSON object with answer, confidence, reasoning, and sources.',
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

export async function generateInfoAgentResult({
  openRouter,
  model,
  request,
}: {
  openRouter: OpenRouter;
  model: string;
  request: OracleRequest;
}): Promise<InfoAgentResult> {
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
          content: buildInfoAgentPrompt(request),
        },
      ],
    },
  });
  const content = response.choices[0]?.message?.content;
  const rawText = extractAssistantText(content);
  const parsed = JSON.parse(rawText) as unknown;

  return parseInfoAgentResult(parsed);
}

export function encodeInfoAgentResult(result: InfoAgentResult) {
  return stringToHex(JSON.stringify(result));
}

export function decodeInfoAgentResult(answer: `0x${string}`): InfoAgentResult | null {
  try {
    const decoded = hexToString(answer);
    return parseInfoAgentResult(JSON.parse(decoded));
  } catch {
    return null;
  }
}
