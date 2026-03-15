import { describe, expect, it } from 'vitest';

import { computeCommitment, phaseFromIndex } from './chain.js';

describe('computeCommitment', () => {
  it('hashes encoded answer bytes with the nonce', () => {
    const commitment = computeCommitment('0x1234', 42n);

    expect(commitment).toMatch(/^0x[a-f0-9]{64}$/);
  });
});

describe('phaseFromIndex', () => {
  it('maps protocol phase indices to names', () => {
    expect(phaseFromIndex(3n)).toBe('judging');
  });
});
