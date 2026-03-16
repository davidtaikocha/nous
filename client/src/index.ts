import type { NousClientConfig } from './config.js';
import { buildRuntime } from './runtime.js';

export function createNousClient(config: NousClientConfig, agentModels?: Map<string, string>) {
  let runtime: ReturnType<typeof buildRuntime> | undefined;

  function getRuntime() {
    runtime ??= buildRuntime({ config, agentModels });
    return runtime;
  }

  return {
    runWorker(signal?: AbortSignal) {
      return getRuntime().worker.run(signal);
    },
    runInfoAgentOnce(requestId: bigint) {
      return getRuntime().worker.runInfoAgentOnce(requestId);
    },
    runJudgeOnce(requestId: bigint) {
      return getRuntime().worker.runJudgeOnce(requestId);
    },
  };
}

export * from './chain.js';
export * from './config.js';
export * from './infoAgent.js';
export * from './judgeAgent.js';
export * from './runtime.js';
export * from './store.js';
export * from './types.js';
export * from './worker.js';
export * from './ipfs.js';
