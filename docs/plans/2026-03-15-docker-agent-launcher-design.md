# Docker Agent Launcher Design

**Date:** 2026-03-15

**Goal**

Add a Docker Compose workflow that can start any local mix of info agents and judge agents from a manifest file, with per-agent model selection and private keys supplied through environment variables rather than checked into git.

## Design

- Add a manifest file format in `client/agents.example.json`
- Add a launcher entrypoint in `client/src/launcher.ts`
- Add a container image in `client/Dockerfile`
- Add a repo-level `docker-compose.yml`

## Manifest Format

The real manifest stays local, while `agents.example.json` is checked in.

Each entry contains:

- `id`
- `role` as `info` or `judge`
- `model`
- `privateKey`

## Runtime Model

The launcher reads shared env:

- `RPC_URL`
- `ORACLE_ADDRESS`
- `CHAIN_ID`
- `OPENROUTER_API_KEY`
- optional `POLL_INTERVAL_MS`
- optional `STATE_DIR`
- optional `AGENTS_FILE`

Then it reads the manifest, takes the private key directly from each agent entry, derives a per-agent state file, and starts one worker instance per manifest entry.

Each manifest entry is translated into a normal `NousClientConfig`:

- info agent entries populate `infoAgentPrivateKeys` with one key
- judge agent entries populate `judgeAgentPrivateKeys` with one key
- `modelId` comes from the entry itself

## Compose Shape

Use one `agents` service.

Why one service:

- supports arbitrary `X` and `Y` counts without editing compose
- supports per-agent model assignment cleanly
- keeps the deployment surface small

Compose mounts:

- local `client/agents.json` as the runtime manifest
- a local state directory for persisted commit/reveal material

Compose passes only shared runtime env such as `RPC_URL`, `ORACLE_ADDRESS`, `CHAIN_ID`, and `OPENROUTER_API_KEY`.

## Acceptance Criteria

- `docker compose up agents` starts all manifest-defined agents
- each agent can use its own OpenRouter model
- no private keys are checked into git
- only example manifest and example env guidance are checked in
