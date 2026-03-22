export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const jwt = process.env.PINATA_JWT;
  if (!jwt) {
    return res.status(500).json({ error: 'IPFS upload not configured' });
  }

  try {
    const response = await fetch('https://api.pinata.cloud/pinning/pinJSONToIPFS', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${jwt}`,
      },
      body: JSON.stringify({ pinataContent: req.body }),
    });

    if (!response.ok) {
      const text = await response.text();
      return res.status(response.status).json({ error: `Pinata error: ${text}` });
    }

    const data = await response.json();
    return res.status(200).json({ cid: data.IpfsHash });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
