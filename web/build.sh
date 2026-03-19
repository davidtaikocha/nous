#!/bin/bash
# Replace placeholders in index.html with environment variables
# Use node for AGENTS_JSON since it may contain special characters
node -e "
const fs = require('fs');
let html = fs.readFileSync('index.html', 'utf8');
const vars = {
  '__RPC_URL__': process.env.RPC_URL || '',
  '__ORACLE_ADDRESS__': process.env.ORACLE_ADDRESS || '',
  '__IPFS_GATEWAY_URL__': process.env.IPFS_GATEWAY_URL || '',
  '__PINATA_JWT__': process.env.PINATA_JWT || '',
  '__AGENTS_JSON__': process.env.AGENTS_JSON || '',
};
for (const [placeholder, value] of Object.entries(vars)) {
  html = html.split(placeholder).join(value.trim());
}
fs.writeFileSync('index.html', html);
"
