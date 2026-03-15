# Docker Agent Launcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a manifest-driven Docker Compose setup that launches any mix of local info agents and judge agents with per-agent OpenRouter models.

**Architecture:** A small launcher reads a JSON manifest, resolves private keys from environment variables, builds one `NousClientConfig` per agent, and runs one worker loop per agent. Docker Compose runs that launcher inside a single Node container and mounts the real manifest plus a state directory.

**Tech Stack:** TypeScript, Node.js, Docker, Docker Compose

---

### Task 1: Add manifest parsing and config derivation

**Files:**
- Create: `client/src/launcher.ts`
- Create: `client/src/launcher.test.ts`

**Step 1: Write the failing test**
- Cover manifest parsing and per-agent config derivation.

**Step 2: Run test to verify it fails**
- Run: `cd client && npm test -- --run src/launcher.test.ts`

**Step 3: Write minimal implementation**
- Parse `agents.json`
- Read `privateKey`
- Build one client config per agent

**Step 4: Run test to verify it passes**
- Run: `cd client && npm test -- --run src/launcher.test.ts`

### Task 2: Add launcher runtime entrypoint

**Files:**
- Modify: `client/package.json`
- Modify: `client/src/launcher.ts`

**Step 1: Write the failing test**
- Add a small test for role mapping if needed.

**Step 2: Run test to verify it fails**
- Run: `cd client && npm test -- --run src/launcher.test.ts`

**Step 3: Write minimal implementation**
- Start all derived workers concurrently
- Handle shutdown signals

**Step 4: Run test to verify it passes**
- Run: `cd client && npm test -- --run src/launcher.test.ts`

### Task 3: Add Docker assets and docs

**Files:**
- Create: `client/Dockerfile`
- Create: `client/agents.example.json`
- Create: `client/.dockerignore`
- Create: `docker-compose.yml`
- Modify: `client/README.md`
- Modify: `README.md`

**Step 1: Write the minimal supporting files**
- Build image
- Mount manifest and state dir
- Document local setup

**Step 2: Verify**
- Run: `cd client && npm test && npm run build`
