import { resolve } from 'node:path';

import { getAddress, isAddress, type Address, type Hex } from 'viem';
import { z } from 'zod';

const privateKeySchema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, 'Expected a 32-byte hex private key');

const envSchema = z.object({
  RPC_URL: z.string().url(),
  ORACLE_ADDRESS: z.string().refine((value) => isAddress(value), 'Expected a valid contract address'),
  CHAIN_ID: z.coerce.number().int().positive(),
  MODEL_ID: z.string().min(1).default('openai/gpt-4.1-mini'),
  OPENROUTER_API_KEY: z.string().min(1).optional(),
  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(5_000),
  STATE_FILE: z.string().min(1).default('.nous-agent-state.json'),
  INFO_AGENT_PRIVATE_KEYS: z.string().default(''),
  JUDGE_AGENT_PRIVATE_KEYS: z.string().default(''),
  PINATA_JWT: z.string().min(1),
  IPFS_GATEWAY_URL: z.string().url().default('https://gateway.pinata.cloud'),
});

export interface NousClientConfig {
  rpcUrl: string;
  oracleAddress: Address;
  chainId: number;
  modelId: string;
  openRouterApiKey?: string;
  pollIntervalMs: number;
  stateFile: string;
  infoAgentPrivateKeys: Hex[];
  judgeAgentPrivateKeys: Hex[];
  pinataJwt: string;
  ipfsGatewayUrl: string;
}

function parsePrivateKeyList(value: string): Hex[] {
  if (!value.trim()) {
    return [];
  }

  return value
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => privateKeySchema.parse(entry) as Hex);
}

export function loadConfig(rawEnv: Record<string, string | undefined>): NousClientConfig {
  const env = envSchema.parse(rawEnv);

  return {
    rpcUrl: env.RPC_URL,
    oracleAddress: getAddress(env.ORACLE_ADDRESS),
    chainId: env.CHAIN_ID,
    modelId: env.MODEL_ID,
    openRouterApiKey: env.OPENROUTER_API_KEY,
    pollIntervalMs: env.POLL_INTERVAL_MS,
    stateFile: resolve(env.STATE_FILE),
    infoAgentPrivateKeys: parsePrivateKeyList(env.INFO_AGENT_PRIVATE_KEYS),
    judgeAgentPrivateKeys: parsePrivateKeyList(env.JUDGE_AGENT_PRIVATE_KEYS),
    pinataJwt: env.PINATA_JWT,
    ipfsGatewayUrl: env.IPFS_GATEWAY_URL,
  };
}
