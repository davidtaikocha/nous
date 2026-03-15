import type { Address, Hex } from 'viem';

export type PhaseName =
  | 'none'
  | 'committing'
  | 'revealing'
  | 'judging'
  | 'finalized'
  | 'distributed'
  | 'failed';

export interface AgentCapabilities {
  capabilities: string[];
  domains: string[];
}

export interface OracleRequest {
  requester: Address;
  rewardAmount: bigint;
  rewardToken: Address;
  bondAmount: bigint;
  bondToken: Address;
  numInfoAgents: bigint;
  deadline: bigint;
  query: string;
  specifications: string;
  requiredCapabilities: AgentCapabilities;
}

export interface RequestContext {
  requestId: bigint;
  phase: PhaseName;
  request: OracleRequest;
  committedAgents: Address[];
  commitHashes: Hex[];
  revealedAgents: Address[];
  revealedAnswers: Hex[];
  selectedJudge: Address;
  revealDeadline: bigint;
  finalized: boolean;
  finalAnswer: Hex;
}

export interface InfoAgentResult {
  answer: string;
  confidence: number;
  reasoning: string;
  sources: string[];
}

export interface DecodedInfoAnswer {
  rawAnswer: Hex;
  parsedAnswer: InfoAgentResult | null;
  text: string;
}

export interface JudgeDecision {
  finalAnswer: string;
  reasoning: string;
  winnerAddresses: Address[];
}

export interface StoredCommit {
  requestId: bigint;
  agentAddress: Address;
  answer: Hex;
  nonce: string;
  commitment: Hex;
  commitTxHash?: Hex;
  revealTxHash?: Hex;
  revealedAt?: string;
}

export interface StateStore {
  saveCommit(commit: StoredCommit): Promise<void>;
  getCommit(requestId: bigint, agentAddress: Address): Promise<StoredCommit | null>;
  markRevealed(requestId: bigint, agentAddress: Address, revealTxHash?: Hex): Promise<void>;
}
