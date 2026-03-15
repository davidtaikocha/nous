import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

import type { Address, Hex } from 'viem';
import { getAddress } from 'viem';

import type { StateStore, StoredCommit } from './types.js';

interface SerializableCommit {
  requestId: string;
  agentAddress: Address;
  answer: Hex;
  nonce: string;
  commitment: Hex;
  commitTxHash?: Hex;
  revealTxHash?: Hex;
  revealedAt?: string;
}

interface FileState {
  commits: Record<string, SerializableCommit>;
}

function makeKey(requestId: bigint, agentAddress: Address): string {
  return `${requestId}:${getAddress(agentAddress).toLowerCase()}`;
}

function serializeCommit(commit: StoredCommit): SerializableCommit {
  return {
    ...commit,
    requestId: commit.requestId.toString(),
  };
}

function deserializeCommit(commit: SerializableCommit): StoredCommit {
  return {
    ...commit,
    requestId: BigInt(commit.requestId),
  };
}

export function createMemoryStateStore(): StateStore {
  const commits = new Map<string, StoredCommit>();

  return {
    async saveCommit(commit) {
      commits.set(makeKey(commit.requestId, commit.agentAddress), commit);
    },
    async getCommit(requestId, agentAddress) {
      return commits.get(makeKey(requestId, agentAddress)) ?? null;
    },
    async markRevealed(requestId, agentAddress, revealTxHash) {
      const key = makeKey(requestId, agentAddress);
      const existing = commits.get(key);
      if (!existing) {
        return;
      }

      commits.set(key, {
        ...existing,
        revealTxHash,
        revealedAt: new Date().toISOString(),
      });
    },
  };
}

export function createFileStateStore(filePath: string): StateStore {
  async function loadState(): Promise<FileState> {
    try {
      const raw = await readFile(filePath, 'utf8');
      return JSON.parse(raw) as FileState;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        return { commits: {} };
      }

      throw error;
    }
  }

  async function saveState(state: FileState): Promise<void> {
    await mkdir(dirname(filePath), { recursive: true });
    await writeFile(filePath, JSON.stringify(state, null, 2), 'utf8');
  }

  return {
    async saveCommit(commit) {
      const state = await loadState();
      state.commits[makeKey(commit.requestId, commit.agentAddress)] = serializeCommit(commit);
      await saveState(state);
    },
    async getCommit(requestId, agentAddress) {
      const state = await loadState();
      const commit = state.commits[makeKey(requestId, agentAddress)];
      return commit ? deserializeCommit(commit) : null;
    },
    async markRevealed(requestId, agentAddress, revealTxHash) {
      const state = await loadState();
      const key = makeKey(requestId, agentAddress);
      const existing = state.commits[key];
      if (!existing) {
        return;
      }

      state.commits[key] = {
        ...existing,
        revealTxHash,
        revealedAt: new Date().toISOString(),
      };
      await saveState(state);
    },
  };
}
