import { OpenRouter } from '@openrouter/sdk';
import { hexToString, stringToHex } from 'viem';
import { z } from 'zod';

import type { InfoAgentResult, OracleRequest } from './types.js';

function coerceToString(v: unknown): string {
  if (typeof v === 'string') return v;
  if (v && typeof v === 'object') {
    if ('text' in v && typeof (v as any).text === 'string') return (v as any).text;
    return JSON.stringify(v);
  }
  return String(v ?? '');
}

export const infoAgentResultSchema = z.object({
  answer: z.any().transform((v) => coerceToString(v) || 'No answer provided.'),
  confidence: z.any().transform((v) => {
    const n = Number(v);
    return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0.5;
  }),
  reasoning: z.any().transform((v) => coerceToString(v) || 'No reasoning provided.'),
  sources: z.array(z.any().transform((v) => coerceToString(v))).default([]),
});

export function parseInfoAgentResult(input: unknown): InfoAgentResult {
  return infoAgentResultSchema.parse(input);
}

export function buildInfoAgentPrompt(request: OracleRequest, specialty?: string): string {
  const capabilities = request.requiredCapabilities.capabilities.join(', ') || 'none';
  const domains = request.requiredCapabilities.domains.join(', ') || 'none';
  const specifications = request.specifications || 'No additional specifications provided.';
  const specialtyLine = specialty && specialty !== 'general'
    ? `Your specialty is "${specialty}". Leverage your domain expertise when relevant.`
    : '';

  return [
    'You are an info agent participating in an oracle council.',
    specialtyLine,
    'Your job is to provide the best possible answer to the question using your knowledge.',
    `Question: ${request.query}`,
    `Specifications: ${specifications}`,
    `Required capabilities: ${capabilities}`,
    `Required domains: ${domains}`,
    'Instructions:',
    '- Always provide a substantive answer. Never abstain or refuse to answer.',
    '- Use your training knowledge to give the best answer you can.',
    '- If the question asks about real-time data, provide your best estimate based on general knowledge (e.g. typical weather patterns, known facts, historical data).',
    '- Clearly state in your reasoning what is based on direct knowledge vs general patterns.',
    '- Use lower confidence when your answer is based on general knowledge rather than specific data.',
    '- Separate observed facts from inference in your reasoning.',
    '- Never invent specific URLs or sources you did not rely on.',
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

export async function generateInfoAgentResult({
  openRouter,
  model,
  request,
  specialty,
}: {
  openRouter: OpenRouter;
  model: string;
  request: OracleRequest;
  specialty?: string;
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
      plugins: [{ id: 'web', max_results: 5 }],
      messages: [
        {
          role: 'system',
          content: 'You have web search access. Search for current information when needed. Return only a valid JSON object matching the requested schema.',
        },
        {
          role: 'user',
          content: buildInfoAgentPrompt(request, specialty),
        },
      ],
    } as any,
  });
  const content = response.choices[0]?.message?.content;
  const rawText = extractAssistantText(content);
  const cleanedText = sanitizeLlmJson(rawText);
  const parsed = JSON.parse(cleanedText) as unknown;

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
