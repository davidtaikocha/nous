const CID_PATTERN = /^(Qm[1-9A-HJ-NP-Za-km-z]{44}|bafy[a-z2-7]{55,})$/;

export interface IpfsService {
  upload(content: object): Promise<string>;
  fetch(cid: string): Promise<unknown>;
}

interface IpfsServiceConfig {
  pinataJwt: string;
  gatewayUrl: string;
  fetchFn?: typeof globalThis.fetch;
}

export function createIpfsService({
  pinataJwt,
  gatewayUrl,
  fetchFn = globalThis.fetch,
}: IpfsServiceConfig): IpfsService {
  return {
    async upload(content: object): Promise<string> {
      const response = await fetchFn('https://api.pinata.cloud/pinning/pinJSONToIPFS', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${pinataJwt}`,
        },
        body: JSON.stringify({ pinataContent: content }),
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(`Pinata upload failed (${response.status}): ${text}`);
      }

      const data = (await response.json()) as { IpfsHash: string };
      const cid = data.IpfsHash;

      if (!CID_PATTERN.test(cid)) {
        throw new Error(`Invalid CID returned from Pinata: ${cid}`);
      }

      return cid;
    },

    async fetch(cid: string): Promise<unknown> {
      const url = `${gatewayUrl}/ipfs/${cid}`;
      const response = await fetchFn(url, {
        headers: { Authorization: `Bearer ${pinataJwt}` },
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(`IPFS fetch failed (${response.status}): ${text}`);
      }

      return response.json();
    },
  };
}
