#!/usr/bin/env node

import { basename } from 'node:path';

import { loadConfig } from './config.js';
import { createNousClient } from './index.js';

function parseRequestId(args: string[]): bigint {
  const requestIndex = args.findIndex((arg) => arg === '--request');
  if (requestIndex === -1 || !args[requestIndex + 1]) {
    throw new Error('Missing required --request <id> argument');
  }

  return BigInt(args[requestIndex + 1]);
}

function resolveCommand(argv: string[]): string {
  const executable = basename(argv[1] ?? '');
  if (executable === 'nous-worker' || executable === 'nous-run-info' || executable === 'nous-run-judge') {
    return executable;
  }

  return argv[2] ?? 'worker';
}

async function main() {
  const command = resolveCommand(process.argv);
  const args = command.startsWith('nous-') ? process.argv.slice(2) : process.argv.slice(3);
  const config = loadConfig(process.env);
  const client = createNousClient(config);

  if (command === 'nous-run-info' || command === 'run-info') {
    await client.runInfoAgentOnce(parseRequestId(args));
    return;
  }

  if (command === 'nous-run-judge' || command === 'run-judge') {
    await client.runJudgeOnce(parseRequestId(args));
    return;
  }

  if (command === 'nous-worker' || command === 'worker') {
    const abortController = new AbortController();
    const exit = () => abortController.abort();

    process.once('SIGINT', exit);
    process.once('SIGTERM', exit);

    await client.runWorker(abortController.signal);
    return;
  }

  throw new Error(`Unknown command: ${command}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
