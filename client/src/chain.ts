import type { Address, Hex, PublicClient, WalletClient } from 'viem';
import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  zeroAddress,
} from 'viem';

import { oracleAbi } from './oracleAbi.js';
import type { PhaseName, RequestContext, OracleRequest } from './types.js';

const erc20Abi = [
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ name: '', type: 'bool' }],
  },
] as const;

const ACTIVE_PHASES = new Set<PhaseName>(['committing', 'revealing', 'judging', 'finalized', 'disputeWindow', 'disputed', 'daoEscalation']);

const PHASE_NAMES: Record<number, PhaseName> = {
  0: 'none',
  1: 'committing',
  2: 'revealing',
  3: 'judging',
  4: 'finalized',
  5: 'distributed',
  6: 'failed',
  7: 'disputeWindow',
  8: 'disputed',
  9: 'daoEscalation',
};

interface ChainClientConfig {
  publicClient: PublicClient;
  walletClients: WalletClient[];
  oracleAddress: Address;
}

interface RawRequest {
  requester: Address;
  rewardAmount: bigint;
  rewardToken: Address;
  bondAmount: bigint;
  bondToken: Address;
  numInfoAgents: bigint;
  deadline: bigint;
  query: string;
  specifications: string;
  requiredCapabilities: {
    capabilities: string[];
    domains: string[];
  };
}

export interface NousChainClient {
  listActiveRequestIds(): Promise<bigint[]>;
  getRequestContext(requestId: bigint): Promise<RequestContext>;
  commit(agentAddress: Address, requestId: bigint, commitment: Hex): Promise<Hex>;
  reveal(agentAddress: Address, requestId: bigint, answer: Hex, nonce: bigint): Promise<Hex>;
  aggregate(
    agentAddress: Address,
    requestId: bigint,
    finalAnswer: Hex,
    winners: Address[],
    reasoning: Hex,
  ): Promise<Hex>;
  endCommitPhase(requestId: bigint): Promise<Hex>;
  endRevealPhase(requestId: bigint): Promise<Hex>;
  distributeRewards(requestId: bigint): Promise<Hex>;
  registerAgent(agentAddress: Address, role: 'info' | 'judge'): Promise<Hex>;
  addStake(agentAddress: Address, amount: bigint): Promise<Hex>;
  requestWithdrawal(agentAddress: Address): Promise<Hex>;
  executeWithdrawal(agentAddress: Address): Promise<Hex>;
  getAgentStake(agentAddress: Address): Promise<{ amount: bigint; role: number; registered: boolean; withdrawRequestTime: bigint }>;
  getSelectedAgents(requestId: bigint): Promise<Address[]>;
  getRegisteredInfoAgents(): Promise<Address[]>;
  getRegisteredJudges(): Promise<Address[]>;
  getMinStakeAmount(): Promise<bigint>;
}

function normalizeRequest(raw: RawRequest): OracleRequest {
  return {
    requester: getAddress(raw.requester),
    rewardAmount: raw.rewardAmount,
    rewardToken: getAddress(raw.rewardToken),
    bondAmount: raw.bondAmount,
    bondToken: getAddress(raw.bondToken),
    numInfoAgents: raw.numInfoAgents,
    deadline: raw.deadline,
    query: raw.query,
    specifications: raw.specifications,
    requiredCapabilities: {
      capabilities: [...raw.requiredCapabilities.capabilities],
      domains: [...raw.requiredCapabilities.domains],
    },
  };
}

export function phaseFromIndex(index: bigint | number): PhaseName {
  return PHASE_NAMES[Number(index)] ?? 'none';
}

export function computeCommitment(answer: Hex, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters([{ type: 'bytes' }, { type: 'uint256' }], [answer, nonce]),
  );
}

export function isActivePhase(phase: PhaseName): boolean {
  return ACTIVE_PHASES.has(phase);
}

const DEFAULT_GAS = 5_000_000n;
const MAX_RETRIES = 3;
const RETRY_DELAY_MS = 2_000;

async function withRetry<T>(fn: () => Promise<T>, retries = MAX_RETRIES): Promise<T> {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (attempt === retries) {
        console.error(`[chain] Tx failed after ${retries} attempts: ${msg}`);
        throw err;
      }
      const isRetryable = /gas|timeout|nonce|underpriced|already known/i.test(msg);
      if (!isRetryable) {
        console.error(`[chain] Tx failed (non-retryable): ${msg}`);
        throw err;
      }
      console.warn(`[chain] Tx attempt ${attempt}/${retries} failed (${msg}), retrying in ${RETRY_DELAY_MS * attempt}ms...`);
      await new Promise((r) => setTimeout(r, RETRY_DELAY_MS * attempt));
    }
  }
  throw new Error('unreachable');
}

export function createNousChainClient({
  publicClient,
  walletClients,
  oracleAddress,
}: ChainClientConfig): NousChainClient {
  const walletMap = new Map<Address, WalletClient>(
    walletClients.map((walletClient) => [getAddress(walletClient.account!.address), walletClient]),
  );

  const maintenanceWallet = walletClients[0];

  function getWalletClient(agentAddress: Address): WalletClient {
    const walletClient = walletMap.get(getAddress(agentAddress));
    if (!walletClient) {
      throw new Error(`No wallet client configured for ${agentAddress}`);
    }

    return walletClient;
  }

  function getMaintenanceWallet(): WalletClient {
    if (!maintenanceWallet) {
      throw new Error('At least one wallet is required for maintenance transactions');
    }

    return maintenanceWallet;
  }

  async function getRequest(requestId: bigint): Promise<OracleRequest> {
    const raw = (await publicClient.readContract({
      address: oracleAddress,
      abi: oracleAbi,
      functionName: 'getRequest',
      args: [requestId],
    })) as RawRequest;

    return normalizeRequest(raw);
  }

  async function getRequestContext(requestId: bigint): Promise<RequestContext> {
    const [phaseIndex, request, commits, reveals, selectedJudge, revealDeadline, resolution, selectedAgents] =
      await Promise.all([
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'phases',
          args: [requestId],
        }),
        getRequest(requestId),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'getCommits',
          args: [requestId],
        }),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'getReveals',
          args: [requestId],
        }),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'selectedJudge',
          args: [requestId],
        }),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'revealDeadlines',
          args: [requestId],
        }),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'getResolution',
          args: [requestId],
        }),
        publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'getSelectedAgents',
          args: [requestId],
        }),
      ]);

    const [committedAgents, commitHashes] = commits as [Address[], Hex[]];
    const [revealedAgents, revealedAnswers] = reveals as [Address[], Hex[]];
    const [finalAnswer, finalized] = resolution as [Hex, boolean];

    return {
      requestId,
      phase: phaseFromIndex(phaseIndex as number),
      request,
      committedAgents: committedAgents.map((agent) => getAddress(agent)),
      commitHashes,
      revealedAgents: revealedAgents.map((agent) => getAddress(agent)),
      revealedAnswers,
      selectedJudge: getAddress(selectedJudge as Address),
      revealDeadline: BigInt(revealDeadline as bigint | number),
      finalized,
      finalAnswer,
      selectedAgents: (selectedAgents as Address[]).map((a) => getAddress(a)),
    };
  }

  return {
    async listActiveRequestIds() {
      const nextRequestId = (await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'nextRequestId',
      })) as bigint;

      const activeRequestIds: bigint[] = [];
      for (let requestId = 1n; requestId < nextRequestId; requestId += 1n) {
        const phaseIndex = (await publicClient.readContract({
          address: oracleAddress,
          abi: oracleAbi,
          functionName: 'phases',
          args: [requestId],
        })) as number;

        if (isActivePhase(phaseFromIndex(phaseIndex))) {
          activeRequestIds.push(requestId);
        }
      }

      return activeRequestIds;
    },
    getRequestContext,
    async commit(agentAddress, requestId, commitment) {
      const request = await getRequest(requestId);
      const walletClient = getWalletClient(agentAddress);
      const isStakingModel = request.bondAmount === 0n;

      if (!isStakingModel && request.bondToken !== zeroAddress && request.bondAmount > 0n) {
        // Legacy bond model: approve ERC-20 (existing logic)
        const currentAllowance = await publicClient.readContract({
          address: request.bondToken,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [agentAddress, oracleAddress],
        });
        if (currentAllowance < request.bondAmount) {
          console.log(`[chain] Approving ${request.bondAmount} bond tokens for ${agentAddress}...`);
          const approveHash = await walletClient.writeContract({
            address: request.bondToken,
            abi: erc20Abi,
            functionName: 'approve',
            args: [oracleAddress, request.bondAmount * 10n],
            chain: walletClient.chain,
            account: walletClient.account!,
            gas: DEFAULT_GAS,
          });
          const approveReceipt = await publicClient.waitForTransactionReceipt({ hash: approveHash });
          if (approveReceipt.status === 'reverted') throw new Error(`approve tx ${approveHash} reverted`);
          console.log(`[chain] Bond token approved: ${approveHash}`);
        }
      }

      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'commit',
        args: [requestId, commitment],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
        value: (!isStakingModel && request.bondToken === zeroAddress) ? request.bondAmount : undefined,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`commit tx ${hash} reverted`);
      return hash;
    },
    async reveal(agentAddress, requestId, answer, nonce) {
      const walletClient = getWalletClient(agentAddress);
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'reveal',
        args: [requestId, answer, nonce],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`reveal tx ${hash} reverted`);
      return hash;
    },
    async aggregate(agentAddress, requestId, finalAnswer, winners, reasoning) {
      const walletClient = getWalletClient(agentAddress);
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'aggregate',
        args: [requestId, finalAnswer, winners, reasoning],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`aggregate tx ${hash} reverted`);
      return hash;
    },
    async endCommitPhase(requestId) {
      const walletClient = getMaintenanceWallet();
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'endCommitPhase',
        args: [requestId],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`endCommitPhase tx ${hash} reverted`);
      return hash;
    },
    async endRevealPhase(requestId) {
      const walletClient = getMaintenanceWallet();
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'endRevealPhase',
        args: [requestId],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`endRevealPhase tx ${hash} reverted`);
      return hash;
    },
    async distributeRewards(requestId) {
      const walletClient = getMaintenanceWallet();
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'distributeRewards',
        args: [requestId],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`distributeRewards tx ${hash} reverted`);
      return hash;
    },
    async registerAgent(agentAddress: Address, role: 'info' | 'judge') {
      const walletClient = getWalletClient(agentAddress);
      const minStake = (await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'minStakeAmount',
      })) as bigint;

      const roleEnum = role === 'info' ? 0 : 1;
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'registerAgent',
        args: [roleEnum],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
        value: minStake,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`registerAgent tx ${hash} reverted`);
      return hash;
    },
    async addStake(agentAddress: Address, amount: bigint) {
      const walletClient = getWalletClient(agentAddress);
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'addStake',
        args: [0n],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
        value: amount,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`addStake tx ${hash} reverted`);
      return hash;
    },
    async requestWithdrawal(agentAddress: Address) {
      const walletClient = getWalletClient(agentAddress);
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'requestWithdrawal',
        args: [],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`requestWithdrawal tx ${hash} reverted`);
      return hash;
    },
    async executeWithdrawal(agentAddress: Address) {
      const walletClient = getWalletClient(agentAddress);
      const hash = await withRetry(() => walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'executeWithdrawal',
        args: [],
        chain: walletClient.chain,
        account: walletClient.account!,
        gas: DEFAULT_GAS,
      }));
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status === 'reverted') throw new Error(`executeWithdrawal tx ${hash} reverted`);
      return hash;
    },
    async getAgentStake(agentAddress: Address) {
      const result = await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'agentStakes',
        args: [agentAddress],
      });
      const [amount, role, registered, withdrawRequestTime] = result as [bigint, number, boolean, bigint];
      return { amount, role, registered, withdrawRequestTime };
    },
    async getSelectedAgents(requestId: bigint) {
      const result = await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'getSelectedAgents',
        args: [requestId],
      });
      return (result as Address[]).map((a) => getAddress(a));
    },
    async getRegisteredInfoAgents() {
      const result = await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'getRegisteredInfoAgents',
      });
      return (result as Address[]).map((a) => getAddress(a));
    },
    async getRegisteredJudges() {
      const result = await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'getRegisteredJudges',
      });
      return (result as Address[]).map((a) => getAddress(a));
    },
    async getMinStakeAmount() {
      return (await publicClient.readContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'minStakeAmount',
      })) as bigint;
    },
  };
}
