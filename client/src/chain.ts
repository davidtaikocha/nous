import type { Address, Hex, PublicClient, WalletClient } from 'viem';
import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  zeroAddress,
} from 'viem';

import { oracleAbi } from './oracleAbi.js';
import type { PhaseName, RequestContext, OracleRequest } from './types.js';

const ACTIVE_PHASES = new Set<PhaseName>(['committing', 'revealing', 'judging']);

const PHASE_NAMES: Record<number, PhaseName> = {
  0: 'none',
  1: 'committing',
  2: 'revealing',
  3: 'judging',
  4: 'finalized',
  5: 'distributed',
  6: 'failed',
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
    const [phaseIndex, request, commits, reveals, selectedJudge, revealDeadline, resolution] =
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

      return walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'commit',
        args: [requestId, commitment],
        chain: walletClient.chain,
        account: walletClient.account!,
        value: request.bondToken === zeroAddress ? request.bondAmount : undefined,
      });
    },
    async reveal(agentAddress, requestId, answer, nonce) {
      const walletClient = getWalletClient(agentAddress);
      return walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'reveal',
        args: [requestId, answer, nonce],
        chain: walletClient.chain,
        account: walletClient.account!,
      });
    },
    async aggregate(agentAddress, requestId, finalAnswer, winners, reasoning) {
      const walletClient = getWalletClient(agentAddress);
      return walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'aggregate',
        args: [requestId, finalAnswer, winners, reasoning],
        chain: walletClient.chain,
        account: walletClient.account!,
      });
    },
    async endCommitPhase(requestId) {
      const walletClient = getMaintenanceWallet();
      return walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'endCommitPhase',
        args: [requestId],
        chain: walletClient.chain,
        account: walletClient.account!,
      });
    },
    async endRevealPhase(requestId) {
      const walletClient = getMaintenanceWallet();
      return walletClient.writeContract({
        address: oracleAddress,
        abi: oracleAbi,
        functionName: 'endRevealPhase',
        args: [requestId],
        chain: walletClient.chain,
        account: walletClient.account!,
      });
    },
  };
}
