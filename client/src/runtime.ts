import { OpenRouter } from '@openrouter/sdk';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { NousClientConfig } from './config.js';
import { createNousChainClient } from './chain.js';
import { generateInfoAgentResult } from './infoAgent.js';
import { generateJudgeDecision } from './judgeAgent.js';
import { createIpfsService } from './ipfs.js';
import { createFileStateStore } from './store.js';
import { createWorker, type InfoAgentRuntime, type JudgeAgentRuntime } from './worker.js';

export function buildRuntime({ config, agentModels, agentSpecialties }: { config: NousClientConfig; agentModels?: Map<string, string>; agentSpecialties?: Map<string, string> }) {
  const chain = defineChain({
    id: config.chainId,
    name: `chain-${config.chainId}`,
    network: `chain-${config.chainId}`,
    nativeCurrency: {
      name: 'Ether',
      symbol: 'ETH',
      decimals: 18,
    },
    rpcUrls: {
      default: {
        http: [config.rpcUrl],
      },
    },
  });

  const publicClient = createPublicClient({
    chain,
    transport: http(config.rpcUrl),
  });

  const allPrivateKeys: Hex[] = [
    ...config.infoAgentPrivateKeys,
    ...config.judgeAgentPrivateKeys,
  ];
  const walletClients = allPrivateKeys.map((privateKey) => {
    const account = privateKeyToAccount(privateKey);
    return createWalletClient({
      account,
      chain,
      transport: http(config.rpcUrl),
    });
  });

  const openRouter = config.openRouterApiKey
    ? new OpenRouter({ apiKey: config.openRouterApiKey })
    : null;

  const infoAgentAddresses = new Set(
    config.infoAgentPrivateKeys.map((privateKey) => getAddress(privateKeyToAccount(privateKey).address)),
  );

  const judgeAgentAddresses = new Set(
    config.judgeAgentPrivateKeys.map((privateKey) => getAddress(privateKeyToAccount(privateKey).address)),
  );

  function getModelForKey(privateKey: Hex): string {
    return agentModels?.get(privateKey) ?? config.modelId;
  }

  function getSpecialtyForKey(privateKey: Hex): string {
    return agentSpecialties?.get(privateKey) ?? 'general';
  }

  const infoAgents: InfoAgentRuntime[] = config.infoAgentPrivateKeys.map((privateKey) => {
    const address = getAddress(privateKeyToAccount(privateKey).address);
    const model = getModelForKey(privateKey);
    const specialty = getSpecialtyForKey(privateKey);
    return {
      address,
      async generate(request) {
        if (!openRouter) {
          throw new Error('OPENROUTER_API_KEY is required to generate info-agent answers');
        }

        return generateInfoAgentResult({ openRouter, model, request, specialty });
      },
    };
  });

  const judgeAgents: JudgeAgentRuntime[] = config.judgeAgentPrivateKeys.map((privateKey) => {
    const address = getAddress(privateKeyToAccount(privateKey).address);
    const model = getModelForKey(privateKey);
    return {
      address,
      async judge(input) {
        if (!openRouter) {
          throw new Error('OPENROUTER_API_KEY is required to generate judge decisions');
        }

        return generateJudgeDecision({
          openRouter,
          model,
          request: input.request,
          revealedAnswers: input.revealedAnswers,
        });
      },
    };
  });

  const chainClient = createNousChainClient({
    publicClient,
    walletClients,
    oracleAddress: config.oracleAddress,
  });
  const ipfs = createIpfsService({
    pinataJwt: config.pinataJwt,
    gatewayUrl: config.ipfsGatewayUrl,
  });
  const store = createFileStateStore(config.stateFile);
  const worker = createWorker({
    chain: chainClient,
    store,
    infoAgents,
    judgeAgents,
    ipfs,
    pollIntervalMs: config.pollIntervalMs,
  });

  return {
    publicClient,
    chainClient,
    store,
    worker,
    infoAgents,
    judgeAgents,
  };
}
