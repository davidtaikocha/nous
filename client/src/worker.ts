import { randomBytes } from 'node:crypto';

import { getAddress, hexToString, type Address, type Hex } from 'viem';

import { computeCommitment } from './chain.js';
import { decodeInfoAgentResult, encodeInfoAgentResult } from './infoAgent.js';
import { encodeJudgeDecision, validateJudgeDecision } from './judgeAgent.js';
import type {
  DecodedInfoAnswer,
  InfoAgentResult,
  JudgeDecision,
  RequestContext,
  StateStore,
} from './types.js';
import type { NousChainClient } from './chain.js';

export interface InfoAgentRuntime {
  address: Address;
  generate(request: RequestContext['request']): Promise<InfoAgentResult>;
}

export interface JudgeAgentRuntime {
  address: Address;
  judge(input: {
    request: RequestContext['request'];
    revealedAnswers: Array<{ agentAddress: Address; answer: DecodedInfoAnswer }>;
  }): Promise<JudgeDecision>;
}

export interface WorkerLogger {
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

interface WorkerConfig {
  chain: NousChainClient;
  store: StateStore;
  infoAgents: InfoAgentRuntime[];
  judgeAgents: JudgeAgentRuntime[];
  pollIntervalMs?: number;
  logger?: WorkerLogger;
  now?: () => bigint;
  createNonce?: () => bigint;
}

function createRandomNonce(): bigint {
  return BigInt(`0x${randomBytes(32).toString('hex')}`);
}

function lower(address: Address): string {
  return getAddress(address).toLowerCase();
}

function decodeAnswer(answer: Hex): DecodedInfoAnswer {
  const parsedAnswer = decodeInfoAgentResult(answer);

  try {
    return {
      rawAnswer: answer,
      parsedAnswer,
      text: parsedAnswer ? JSON.stringify(parsedAnswer) : hexToString(answer),
    };
  } catch {
    return {
      rawAnswer: answer,
      parsedAnswer,
      text: answer,
    };
  }
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(resolve, ms);
    if (!signal) {
      return;
    }

    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timeout);
        reject(new Error('Worker aborted'));
      },
      { once: true },
    );
  });
}

export function createWorker({
  chain,
  store,
  infoAgents,
  judgeAgents,
  pollIntervalMs = 5_000,
  logger = console,
  now = () => BigInt(Math.floor(Date.now() / 1_000)),
  createNonce = createRandomNonce,
}: WorkerConfig) {
  async function maybeAdvancePhase(context: RequestContext): Promise<RequestContext> {
    const currentTime = now();

    if (context.phase === 'committing' && currentTime > context.request.deadline) {
      await chain.endCommitPhase(context.requestId);
      return chain.getRequestContext(context.requestId);
    }

    if (context.phase === 'revealing' && context.revealDeadline > 0n && currentTime > context.revealDeadline) {
      await chain.endRevealPhase(context.requestId);
      return chain.getRequestContext(context.requestId);
    }

    return context;
  }

  async function handleCommitting(context: RequestContext): Promise<void> {
    const committed = new Set(context.committedAgents.map(lower));
    let remainingSlots = Number(context.request.numInfoAgents - BigInt(context.committedAgents.length));

    for (const agent of infoAgents) {
      if (remainingSlots <= 0) {
        break;
      }
      if (committed.has(lower(agent.address))) {
        continue;
      }

      const result = await agent.generate(context.request);
      const answer = encodeInfoAgentResult(result);
      const nonce = createNonce();
      const commitment = computeCommitment(answer, nonce);

      await store.saveCommit({
        requestId: context.requestId,
        agentAddress: agent.address,
        answer,
        nonce: nonce.toString(),
        commitment,
      });

      const commitTxHash = await chain.commit(agent.address, context.requestId, commitment);
      await store.saveCommit({
        requestId: context.requestId,
        agentAddress: agent.address,
        answer,
        nonce: nonce.toString(),
        commitment,
        commitTxHash,
      });

      committed.add(lower(agent.address));
      remainingSlots -= 1;
      logger.info(`Committed request ${context.requestId} as ${agent.address}`);
    }
  }

  async function handleRevealing(context: RequestContext): Promise<void> {
    const revealed = new Set(context.revealedAgents.map(lower));

    for (const committedAgent of context.committedAgents) {
      const normalized = getAddress(committedAgent);
      const agent = infoAgents.find((candidate) => lower(candidate.address) === lower(normalized));
      if (!agent || revealed.has(lower(normalized))) {
        continue;
      }

      const commit = await store.getCommit(context.requestId, normalized);
      if (!commit) {
        logger.warn(`Missing stored reveal material for request ${context.requestId} and agent ${normalized}`);
        continue;
      }

      if (commit.revealedAt) {
        continue;
      }

      const revealTxHash = await chain.reveal(
        normalized,
        context.requestId,
        commit.answer,
        BigInt(commit.nonce),
      );
      await store.markRevealed(context.requestId, normalized, revealTxHash);
      logger.info(`Revealed request ${context.requestId} as ${normalized}`);
    }
  }

  async function handleJudging(context: RequestContext): Promise<void> {
    const selectedJudge = lower(context.selectedJudge);
    const judge = judgeAgents.find((candidate) => lower(candidate.address) === selectedJudge);
    if (!judge) {
      return;
    }

    const revealedAnswers = context.revealedAgents.map((agentAddress, index) => ({
      agentAddress,
      answer: decodeAnswer(context.revealedAnswers[index] ?? '0x'),
    }));

    const decision = validateJudgeDecision(
      await judge.judge({
        request: context.request,
        revealedAnswers,
      }),
      context.revealedAgents,
    );
    const encoded = encodeJudgeDecision(decision);

    await chain.aggregate(
      judge.address,
      context.requestId,
      encoded.finalAnswer,
      decision.winnerAddresses,
      encoded.reasoning,
    );

    logger.info(`Aggregated request ${context.requestId} as ${judge.address}`);
  }

  async function processRequest(
    requestId: bigint,
    options: { includeInfo?: boolean; includeJudge?: boolean } = {},
  ): Promise<void> {
    const includeInfo = options.includeInfo ?? true;
    const includeJudge = options.includeJudge ?? true;

    let context = await chain.getRequestContext(requestId);
    context = await maybeAdvancePhase(context);

    if (includeInfo && context.phase === 'committing') {
      await handleCommitting(context);
      return;
    }

    if (includeInfo && context.phase === 'revealing') {
      await handleRevealing(context);
      return;
    }

    if (includeJudge && context.phase === 'judging') {
      await handleJudging(context);
    }
  }

  return {
    async tick(requestIds?: bigint[]) {
      const activeRequestIds = requestIds ?? (await chain.listActiveRequestIds());

      for (const requestId of activeRequestIds) {
        try {
          await processRequest(requestId);
        } catch (error) {
          logger.error(
            `Failed to process request ${requestId}: ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        }
      }
    },
    async runInfoAgentOnce(requestId: bigint) {
      await processRequest(requestId, { includeInfo: true, includeJudge: false });
    },
    async runJudgeOnce(requestId: bigint) {
      await processRequest(requestId, { includeInfo: false, includeJudge: true });
    },
    async run(signal?: AbortSignal) {
      while (!signal?.aborted) {
        await this.tick();
        await delay(pollIntervalMs, signal);
      }
    },
  };
}
