import { describe, expect, it, vi, beforeEach } from 'vitest';
import { createIpfsService } from './ipfs.js';

describe('createIpfsService', () => {
  const mockFetch = vi.fn();

  beforeEach(() => {
    mockFetch.mockReset();
  });

  describe('upload', () => {
    it('uploads JSON to Pinata and returns CID', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ IpfsHash: 'QmYwAPJzv5CZsnANfSPFkVdR4aaXrSHipKchUEeGzTpsRF' }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      const cid = await ipfs.upload({ answer: 'hello', confidence: 0.9 });

      expect(cid).toBe('QmYwAPJzv5CZsnANfSPFkVdR4aaXrSHipKchUEeGzTpsRF');
      expect(mockFetch).toHaveBeenCalledWith(
        'https://api.pinata.cloud/pinning/pinJSONToIPFS',
        expect.objectContaining({
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: 'Bearer test-jwt',
          },
          body: JSON.stringify({ pinataContent: { answer: 'hello', confidence: 0.9 } }),
        }),
      );
    });

    it('throws on non-ok response', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 401,
        text: async () => 'Unauthorized',
      });

      const ipfs = createIpfsService({
        pinataJwt: 'bad-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.upload({ data: 'test' })).rejects.toThrow('Pinata upload failed (401)');
    });

    it('throws on invalid CID format', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ IpfsHash: 'not-a-valid-cid' }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.upload({ data: 'test' })).rejects.toThrow('Invalid CID');
    });
  });

  describe('fetch', () => {
    it('fetches JSON from IPFS gateway', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({ answer: 'hello', confidence: 0.9 }),
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      const result = await ipfs.fetch('QmYwAPJzv5CZsnANfSPFkVdR4aaXrSHipKchUEeGzTpsRF');

      expect(result).toEqual({ answer: 'hello', confidence: 0.9 });
      expect(mockFetch).toHaveBeenCalledWith(
        'https://test.mypinata.cloud/ipfs/QmYwAPJzv5CZsnANfSPFkVdR4aaXrSHipKchUEeGzTpsRF',
      );
    });

    it('throws on non-ok response', async () => {
      mockFetch.mockResolvedValueOnce({
        ok: false,
        status: 404,
        text: async () => 'Not Found',
      });

      const ipfs = createIpfsService({
        pinataJwt: 'test-jwt',
        gatewayUrl: 'https://test.mypinata.cloud',
        fetchFn: mockFetch,
      });

      await expect(ipfs.fetch('QmYwAPJzv5CZsnANfSPFkVdR4aaXrSHipKchUEeGzTpsRF')).rejects.toThrow(
        'IPFS fetch failed (404)',
      );
    });
  });
});
