#!/usr/bin/env node

import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

import { z } from 'zod';
import type { Hex } from 'viem';

import type { NousClientConfig } from './config.js';
import { loadConfig } from './config.js';
import { createNousClient } from './index.js';

const agentRoleSchema = z.enum(['info', 'judge']);
const privateKeySchema = z
  .string()
  .regex(/^0x[0-9a-fA-F]{64}$/, 'Expected a 32-byte hex private key');

const agentManifestSchema = z.object({
  agents: z.array(
    z.object({
      id: z.string().min(1),
      role: agentRoleSchema,
      model: z.string().min(1),
      privateKey: privateKeySchema,
    }),
  ),
});

export type AgentManifest = z.infer<typeof agentManifestSchema>;
export type AgentManifestEntry = AgentManifest['agents'][number];

export function parseAgentManifest(input: unknown): AgentManifest {
  return agentManifestSchema.parse(input);
}

export async function loadAgentManifest(filePath: string): Promise<AgentManifest> {
  const raw = await readFile(filePath, 'utf8');
  return parseAgentManifest(JSON.parse(raw));
}

export function buildAgentConfigs({
  manifest,
  baseConfig,
  stateDir,
}: {
  manifest: AgentManifest;
  baseConfig: NousClientConfig;
  stateDir: string;
}): Array<{ id: string; role: AgentManifestEntry['role']; config: NousClientConfig }> {
  return manifest.agents.map((agent) => {
    const privateKey = agent.privateKey as Hex;

    return {
      id: agent.id,
      role: agent.role,
      config: {
        ...baseConfig,
        modelId: agent.model,
        stateFile: join(stateDir, `${agent.id}.json`),
        infoAgentPrivateKeys: agent.role === 'info' ? [privateKey] : [],
        judgeAgentPrivateKeys: agent.role === 'judge' ? [privateKey] : [],
      },
    };
  });
}

export async function runLauncher({
  env,
  signal,
}: {
  env: Record<string, string | undefined>;
  signal?: AbortSignal;
}): Promise<void> {
  const baseConfig = loadConfig(env);
  const agentsFile = resolve(env.AGENTS_FILE ?? 'agents.json');
  const stateDir = resolve(env.STATE_DIR ?? 'state');
  const manifest = await loadAgentManifest(agentsFile);
  const agentConfigs = buildAgentConfigs({
    manifest,
    baseConfig,
    stateDir,
  });

  await Promise.all(
    agentConfigs.map(async ({ id, config }) => {
      const client = createNousClient(config);
      try {
        await client.runWorker(signal);
      } catch (error) {
        if (signal?.aborted) {
          return;
        }

        throw new Error(
          `Agent ${id} stopped unexpectedly: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }),
  );
}

async function main() {
  const abortController = new AbortController();
  const exit = () => abortController.abort();

  process.once('SIGINT', exit);
  process.once('SIGTERM', exit);

  await runLauncher({
    env: process.env,
    signal: abortController.signal,
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
