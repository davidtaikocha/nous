import { randomBytes } from 'node:crypto';

import { getAddress, hexToString, stringToHex, type Address, type Hex } from 'viem';

import { computeCommitment } from './chain.js';
import { parseInfoAgentResult } from './infoAgent.js';
import type { IpfsService } from './ipfs.js';
import { validateJudgeDecision } from './judgeAgent.js';
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
  ipfs: IpfsService;
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
  ipfs,
  pollIntervalMs = 5_000,
  logger = console,
  now = () => BigInt(Math.floor(Date.now() / 1_000)),
  createNonce = createRandomNonce,
}: WorkerConfig) {
  async function resolveAnswer(answerHex: Hex): Promise<DecodedInfoAnswer> {
    const cidOrJson = hexToString(answerHex);

    // Detect IPFS CID (CIDv0 or CIDv1) vs raw JSON
    if (cidOrJson.startsWith('Qm') || cidOrJson.startsWith('bafy')) {
      const content = await ipfs.fetch(cidOrJson);
      const parsedAnswer = parseInfoAgentResult(content);
      return {
        rawAnswer: answerHex,
        parsedAnswer,
        text: JSON.stringify(parsedAnswer),
      };
    }

    // Fallback: treat as raw JSON (backward compat)
    try {
      const parsedAnswer = parseInfoAgentResult(JSON.parse(cidOrJson));
      return {
        rawAnswer: answerHex,
        parsedAnswer,
        text: JSON.stringify(parsedAnswer),
      };
    } catch {
      return {
        rawAnswer: answerHex,
        parsedAnswer: null,
        text: cidOrJson,
      };
    }
  }

  function isCid(value: string): boolean {
    return value.startsWith('Qm') || value.startsWith('bafy');
  }

  async function resolveString(value: string): Promise<string> {
    if (!isCid(value)) return value;
    const content = await ipfs.fetch(value);
    if (typeof content === 'string') return content;
    if (content && typeof content === 'object' && 'content' in content && typeof (content as any).content === 'string') {
      return (content as any).content;
    }
    return JSON.stringify(content);
  }

  async function resolveRequestFields(request: RequestContext['request']): Promise<RequestContext['request']> {
    const [query, specifications] = await Promise.all([
      resolveString(request.query),
      resolveString(request.specifications),
    ]);
    if (query === request.query && specifications === request.specifications) return request;
    return { ...request, query, specifications };
  }

  async function maybeAdvancePhase(context: RequestContext): Promise<RequestContext> {
    const currentTime = now();

    if (context.phase === 'committing' && currentTime > context.request.deadline) {
      logger.info(`[req=${context.requestId}] Commit deadline passed, ending commit phase`);
      await chain.endCommitPhase(context.requestId);
      const updated = await chain.getRequestContext(context.requestId);
      logger.info(`[req=${context.requestId}] Phase transitioned: committing → ${updated.phase}`);
      return updated;
    }

    if (context.phase === 'revealing' && context.revealDeadline > 0n && currentTime > context.revealDeadline) {
      logger.info(`[req=${context.requestId}] Reveal deadline passed, ending reveal phase`);
      await chain.endRevealPhase(context.requestId);
      const updated = await chain.getRequestContext(context.requestId);
      logger.info(`[req=${context.requestId}] Phase transitioned: revealing → ${updated.phase}`);
      return updated;
    }

    return context;
  }

  async function handleCommitting(context: RequestContext): Promise<void> {
    const committed = new Set(context.committedAgents.map(lower));
    let remainingSlots = Number(context.request.numInfoAgents - BigInt(context.committedAgents.length));
    logger.info(`[req=${context.requestId}] Committing: ${context.committedAgents.length}/${context.request.numInfoAgents} agents committed, ${remainingSlots} slots remaining`);

    for (const agent of infoAgents) {
      if (remainingSlots <= 0) {
        logger.info(`[req=${context.requestId}] All slots filled, skipping ${agent.address}`);
        break;
      }
      if (committed.has(lower(agent.address))) {
        logger.info(`[req=${context.requestId}] Agent ${agent.address} already committed, skipping`);
        continue;
      }

      logger.info(`[req=${context.requestId}] Agent ${agent.address} generating answer...`);
      const result = await agent.generate(context.request);
      logger.info(`[req=${context.requestId}] Agent ${agent.address} generated answer (confidence=${result.confidence}): "${result.answer.slice(0, 80)}..."`);

      const cid = await ipfs.upload(result);
      logger.info(`[req=${context.requestId}] Agent ${agent.address} uploaded answer to IPFS: ${cid}`);
      const answer = stringToHex(cid);
      const nonce = createNonce();
      const commitment = computeCommitment(answer, nonce);

      logger.info(`[req=${context.requestId}] Agent ${agent.address} saving commit to store...`);
      await store.saveCommit({
        requestId: context.requestId,
        agentAddress: agent.address,
        answer,
        nonce: nonce.toString(),
        commitment,
      });

      logger.info(`[req=${context.requestId}] Agent ${agent.address} sending commit tx...`);
      const commitTxHash = await chain.commit(agent.address, context.requestId, commitment);
      logger.info(`[req=${context.requestId}] Agent ${agent.address} commit tx: ${commitTxHash}`);

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
      logger.info(`[req=${context.requestId}] Committed as ${agent.address} ✓`);
    }
  }

  async function handleRevealing(context: RequestContext): Promise<void> {
    const revealed = new Set(context.revealedAgents.map(lower));
    logger.info(`[req=${context.requestId}] Revealing: ${context.revealedAgents.length}/${context.committedAgents.length} agents revealed`);

    for (const committedAgent of context.committedAgents) {
      const normalized = getAddress(committedAgent);
      const agent = infoAgents.find((candidate) => lower(candidate.address) === lower(normalized));

      if (!agent) {
        logger.info(`[req=${context.requestId}] Agent ${normalized} not managed by us, skipping`);
        continue;
      }

      if (revealed.has(lower(normalized))) {
        logger.info(`[req=${context.requestId}] Agent ${normalized} already revealed on-chain, skipping`);
        continue;
      }

      const commit = await store.getCommit(context.requestId, normalized);
      if (!commit) {
        logger.warn(`[req=${context.requestId}] No stored commit data for agent ${normalized}, cannot reveal`);
        continue;
      }

      if (commit.revealedAt) {
        logger.info(`[req=${context.requestId}] Agent ${normalized} already marked revealed in store, skipping`);
        continue;
      }

      logger.info(`[req=${context.requestId}] Agent ${normalized} sending reveal tx...`);
      const revealTxHash = await chain.reveal(
        normalized,
        context.requestId,
        commit.answer,
        BigInt(commit.nonce),
      );
      logger.info(`[req=${context.requestId}] Agent ${normalized} reveal tx: ${revealTxHash}`);

      await store.markRevealed(context.requestId, normalized, revealTxHash);
      logger.info(`[req=${context.requestId}] Revealed as ${normalized} ✓`);
    }
  }

  async function handleJudging(context: RequestContext): Promise<void> {
    const selectedJudge = lower(context.selectedJudge);
    const judge = judgeAgents.find((candidate) => lower(candidate.address) === selectedJudge);

    if (!judge) {
      logger.info(`[req=${context.requestId}] Selected judge ${context.selectedJudge} not managed by us, skipping`);
      return;
    }

    logger.info(`[req=${context.requestId}] Judging: ${context.revealedAgents.length} revealed answers to evaluate`);

    const revealedAnswers = await Promise.all(
      context.revealedAgents.map(async (agentAddress, index) => ({
        agentAddress,
        answer: await resolveAnswer(context.revealedAnswers[index] ?? '0x'),
      })),
    );

    logger.info(`[req=${context.requestId}] Judge ${judge.address} generating decision...`);
    const decision = validateJudgeDecision(
      await judge.judge({
        request: context.request,
        revealedAnswers,
      }),
      context.revealedAgents,
    );
    logger.info(`[req=${context.requestId}] Judge decision: winners=${decision.winnerAddresses.join(', ')}, answer="${decision.finalAnswer.slice(0, 80)}..."`);

    const [finalAnswerCid, reasoningCid] = await Promise.all([
      ipfs.upload({ content: decision.finalAnswer }),
      ipfs.upload({ content: decision.reasoning }),
    ]);
    logger.info(`[req=${context.requestId}] Judge uploaded to IPFS: finalAnswer=${finalAnswerCid}, reasoning=${reasoningCid}`);

    logger.info(`[req=${context.requestId}] Judge ${judge.address} sending aggregate tx...`);
    await chain.aggregate(
      judge.address,
      context.requestId,
      stringToHex(finalAnswerCid),
      decision.winnerAddresses,
      stringToHex(reasoningCid),
    );

    logger.info(`[req=${context.requestId}] Aggregated by judge ${judge.address} ✓`);
  }

  async function processRequest(
    requestId: bigint,
    options: { includeInfo?: boolean; includeJudge?: boolean } = {},
  ): Promise<void> {
    const includeInfo = options.includeInfo ?? true;
    const includeJudge = options.includeJudge ?? true;

    let context = await chain.getRequestContext(requestId);
    context = { ...context, request: await resolveRequestFields(context.request) };
    logger.info(`[req=${requestId}] Processing: phase=${context.phase}, query="${context.request.query.slice(0, 60)}"`);
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
      return;
    }

    if (context.phase === 'finalized') {
      logger.info(`[req=${requestId}] Request finalized, distributing rewards...`);
      await chain.distributeRewards(requestId);
      logger.info(`[req=${requestId}] Rewards distributed ✓`);
      return;
    }

    if (context.phase === 'distributed' || context.phase === 'failed') {
      logger.info(`[req=${requestId}] Request is ${context.phase}, no action needed`);
    }
  }

  return {
    async tick(requestIds?: bigint[]) {
      const activeRequestIds = requestIds ?? (await chain.listActiveRequestIds());
      logger.info(`[tick] ${activeRequestIds.length} active request(s): [${activeRequestIds.join(', ')}]`);

      for (const requestId of activeRequestIds) {
        try {
          await processRequest(requestId);
        } catch (error) {
          logger.error(
            `[req=${requestId}] Failed: ${
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
    async startup() {
      logger.info('[startup] Scanning for pending work...');
      const activeRequestIds = await chain.listActiveRequestIds();

      if (activeRequestIds.length === 0) {
        logger.info('[startup] No pending requests found');
        return;
      }

      const infoAddresses = new Set(infoAgents.map((a) => lower(a.address)));
      const judgeAddresses = new Set(judgeAgents.map((a) => lower(a.address)));

      for (const requestId of activeRequestIds) {
        try {
          const ctx = await chain.getRequestContext(requestId);
          const committed = new Set(ctx.committedAgents.map(lower));
          const revealed = new Set(ctx.revealedAgents.map(lower));

          const uncommitted = infoAgents.filter((a) => !committed.has(lower(a.address)));
          const unrevealed = ctx.committedAgents.filter(
            (a) => infoAddresses.has(lower(a)) && !revealed.has(lower(a)),
          );
          const isOurJudge = ctx.selectedJudge !== '0x0000000000000000000000000000000000000000'
            && judgeAddresses.has(lower(ctx.selectedJudge));

          logger.info(
            `[startup] Request #${requestId}: phase=${ctx.phase}, ` +
            `committed=${ctx.committedAgents.length}/${ctx.request.numInfoAgents}, ` +
            `revealed=${ctx.revealedAgents.length}/${ctx.committedAgents.length}` +
            (uncommitted.length > 0 ? `, uncommitted=[${uncommitted.map((a) => a.address).join(', ')}]` : '') +
            (unrevealed.length > 0 ? `, unrevealed=[${unrevealed.join(', ')}]` : '') +
            (ctx.phase === 'judging' && isOurJudge ? `, judge=${ctx.selectedJudge} (OURS)` : ''),
          );

          if (ctx.phase === 'committing' && uncommitted.length > 0) {
            logger.info(`[startup] Processing uncommitted agents for request #${requestId}`);
          }
          if (ctx.phase === 'revealing' && unrevealed.length > 0) {
            logger.info(`[startup] Processing unrevealed agents for request #${requestId}`);
          }
          if (ctx.phase === 'judging' && isOurJudge) {
            logger.info(`[startup] Processing pending judgment for request #${requestId}`);
          }

          await processRequest(requestId);
        } catch (error) {
          logger.error(
            `[startup] Failed to process request ${requestId}: ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        }
      }

      logger.info(`[startup] Startup scan complete, processed ${activeRequestIds.length} request(s)`);
    },
    async run(signal?: AbortSignal) {
      await this.startup();
      while (!signal?.aborted) {
        await this.tick();
        await delay(pollIntervalMs, signal);
      }
    },
  };
}
