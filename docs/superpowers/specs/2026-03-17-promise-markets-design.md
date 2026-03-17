# Promise Markets — Design Spec

A protocol where anyone can make a public, on-chain promise with economic stakes, and anyone else can bet for or against them keeping it. Resolved by the Nous oracle council.

## Core Concept

1. **Maker** posts a promise in natural language with verification criteria and a bond
2. A **market** opens — traders buy YES (they'll keep it) or NO (they won't) shares
3. At the deadline, the **Nous oracle council** evaluates the promise against the maker's stated verification criteria
4. The council resolves the market. Winners collect. The maker's bond is returned or forfeited based on the outcome

### What Makes This Different

- **Maker has skin in the game** — bond + reputation consequences, not just spectators betting
- **Semantic resolution** — the oracle council handles ambiguity, edge cases, and spirit-vs-letter disputes
- **Persistent reputation** — on-chain history of kept/broken promises, composable with other protocols
- **Partial resolution** — real-world promises are messy; the council can grade fulfillment on a percentage scale

## Promise Creation

### Required Fields

| Field | Description | Example |
|---|---|---|
| `promise` | Natural language statement of the commitment | *"I will open-source our protocol's codebase"* |
| `verificationCriteria` | Specific, testable criteria for how fulfillment will be judged | *"Full source code published on a public GitHub repo under MIT or Apache 2.0 license. Must include smart contracts, client code, and documentation. Forks/mirrors don't count — must be official org repo."* |
| `deadline` | Unix timestamp when the promise expires and resolution begins | June 30, 2026 |
| `bond` | Amount staked by the maker in the market's denomination token | 1 ETH |
| `category` | Promise type — determines market rules | Personal, Project, Public Figure, Inter-party |

### Optional Fields

| Field | Description |
|---|---|
| `evidenceLinks` | Links to relevant context (repo URL, roadmap doc, etc.) |

### Constraints

- Minimum bond threshold to prevent spam (configurable by governance)
- `verificationCriteria` is required and immutable after creation — the maker cannot move the goalposts
- Promises with vague or untestable criteria will naturally attract less trading volume (market self-correction)
- All bonds and trading are denominated in the **same token** per market (ETH or a specific ERC-20) — no cross-token complexity

### Third-Party Promises

Anyone can create a promise *about* a public figure or organization. These:
- Require a **creator deposit** (not a "promise bond" but a market creation deposit to fund oracle resolution and prevent spam). Minimum: enough to cover oracle `rewardAmount` + protocol fees. Returned to creator after resolution.
- Are pure prediction markets on whether someone else follows through
- Still require verification criteria (prevents vague, unjudgeable markets)
- Don't affect the third party's reputation score (they didn't opt in)
- Are visually distinguished from bonded self-promises in the UI and on-chain (a `isThirdParty` flag)

### Early Resolution & Cancellation

- **Maker-initiated early resolution:** If the maker fulfills their promise before the deadline, they can call `requestEarlyResolution()` with evidence. This triggers a shortened resolution window (oracle query + 24h challenge period instead of 48h).
- **Market cancellation:** If a market has zero trading volume after 7 days, anyone can cancel it. The maker's bond is returned minus the creation fee.
- **Emergency cancellation:** The protocol owner can cancel a market in extraordinary circumstances (e.g., promise becomes logically impossible). Maker bond returned, all share positions refunded at cost basis.

## Judge Transparency

When a promise is created, the system snapshots the **current global judge pool** from NousOracle and records it on the PromiseMarket contract. This is a read-only snapshot — it does not restrict which judge the oracle selects.

### How It Works

1. `PromiseMarket` reads the full judge list from NousOracle at promise creation time
2. The snapshot (addresses + metadata) is stored on-chain in the promise struct
3. Traders can see every judge who *could* be selected when resolution happens
4. At resolution, NousOracle selects a judge from its global pool per its existing random selection logic (no oracle modification needed)
5. If the judge pool changes between creation and resolution (judges added/removed), the actual resolution uses the **current** pool, not the snapshot. The snapshot is informational — it tells traders "this was the pool when the market opened"

### What Traders See

```
Promise:       "I will open-source our protocol's codebase"
Verification:  "Full source on public GitHub, MIT/Apache 2.0..."
Deadline:      June 30, 2026
Maker Bond:    1 ETH
Judge Pool (at creation): 5 judges
  -> 0xA3f...  (Grok 4.1, specialty: software)
  -> 0x7B2...  (DeepSeek v3.2, specialty: general)
  -> 0xC91...  (Gemini 2.5, specialty: general)
  -> 0x1D4...  (GPT-4, specialty: software)
  -> 0xE58...  (DeepSeek v3.2, specialty: open-source)
Market:        YES 0.72 / NO 0.28
```

### Future Enhancement: Per-Request Judge Pools

A future NousOracle upgrade (via UUPS proxy) could add an optional `allowedJudges` parameter to `createRequest()`, enabling PromiseMarket to lock a specific judge subset per resolution. This would require:
- A new `allowedJudges` field on the `Request` struct
- Modified `_transitionToJudging()` to select from the restricted pool when specified
- A migration plan via the UUPS upgrade path

This is explicitly out of scope for v1. The snapshot approach provides transparency without oracle modifications.

## Market Mechanics

### AMM Design

**Curve type:** Logarithmic Market Scoring Rule (LMSR), same as Gnosis/Omen prediction markets. LMSR is well-suited for binary outcome markets — it always provides liquidity and has bounded loss for the liquidity provider.

**Share tokens:** YES and NO shares are **ERC-1155** tokens (multi-token in a single contract, gas-efficient for batch operations). Each promise market has a unique token ID pair.

**Initial liquidity:** Seeded by the protocol from the **maker's bond**. A fixed percentage of the bond (e.g., 20%) is allocated as the LMSR liquidity parameter `b`. The remaining 80% stays in the bond escrow. This means:
- Every market has liquidity from the start — no cold-start problem
- Larger bonds = deeper liquidity = tighter spreads
- The maker's bond serves double duty: commitment signal + liquidity provision

**LMSR subsidy cost:** The LMSR liquidity provider has a bounded maximum loss of `b * ln(2)` (approximately 13.9% of `b`). For a 1 ETH bond with `b = 0.2 ETH`, the maximum subsidy loss is ~0.028 ETH. This cost is absorbed by the **protocol fee pool**, not the maker. The maker's full bond (minus creation fee) is returned on KEPT resolution. The protocol treats the LMSR subsidy as a cost of doing business — it's covered by the 2% trading fees collected on the market. In markets with sufficient volume, trading fees will far exceed the subsidy cost. In low-volume markets, the protocol may take a small loss per market — this is acceptable as a growth cost.

**Trading mechanics:**
- Traders buy YES or NO shares by sending the market's denomination token
- Share prices range from 0 to 1 (denominated in the market token)
- LMSR pricing: `price_YES = e^(q_yes/b) / (e^(q_yes/b) + e^(q_no/b))`
- Maximum trade size is bounded by the LMSR's `b` parameter to limit slippage
- Trading fee: 1-2% per trade, added on top of the LMSR price

**Settlement / redemption:**
- **KEPT:** Each YES share redeems for 1 token. NO shares worth 0.
- **BROKEN:** Each NO share redeems for 1 token. YES shares worth 0.
- **PARTIALLY_KEPT at X%:** Each YES share redeems for `X/100` tokens. Each NO share redeems for `(100-X)/100` tokens.

### Resolution Flow

Resolution is **asynchronous** — it involves an off-chain oracle cycle that takes hours to days.

1. **Deadline passes** -> market trading stops, market enters **resolution pending** state
2. Anyone can call `triggerResolution()` (can also submit additional evidence links)
3. `triggerResolution()` calls `createRequest()` on NousOracle (see Oracle Integration for exact parameters)
4. **Off-chain oracle cycle begins:** info agents commit -> reveal -> judge synthesizes (this is the existing Nous lifecycle, taking hours/days depending on oracle configuration)
5. Once the oracle request reaches `Finalized` state, anyone can call `settleMarket()` on PromiseMarket
6. `settleMarket()` reads the oracle's `finalAnswer`, parses the structured result, and transitions the market to **settled**
7. **48-hour challenge window** begins (see Disputes below)
8. After the challenge window (or after a dispute resolves), the market transitions to **finalized** — share holders can redeem

### Timing: Promise Deadline vs. Oracle Deadline

The promise's `deadline` and the oracle request's `deadline` parameter serve different purposes:
- **Promise deadline:** When the promise expires (set by maker)
- **Oracle commit deadline:** When agents must submit commitments (set by PromiseMarket)

When `triggerResolution()` fires, it sets the oracle request's `deadline` = `block.timestamp + COMMIT_WINDOW` (e.g., 24 hours). This gives agents time to research and commit their evaluations. The full oracle cycle (commit + reveal + judging) adds approximately 48-72 hours after the promise deadline before settlement.

### Partial Resolution

The "Partially Kept" mechanic handles real-world messiness:
- *"I'll ship the MVP by March"* and they ship 80% of it -> council returns PARTIALLY_KEPT at 80%
- YES holders redeem at 0.80 per share, NO holders redeem at 0.20 per share
- The maker's bond is returned proportionally (80% returned, 20% forfeited to NO holders)

### Bond Mechanics

- **Kept** -> maker gets full bond back (minus creation fee). AMM liquidity is returned to the protocol fee pool, which absorbs any LMSR subsidy loss. Maker also receives a cut of trading fees.
- **Broken** -> bond forfeited, distributed to NO holders pro-rata
- **Partially kept** -> bond returned proportionally to the kept percentage

### Dispute Mechanism (v1: Simple)

After oracle settlement, there is a **48-hour challenge window** before the market finalizes:

1. Anyone can call `disputeResolution()` with a stake (minimum: 0.1 ETH equivalent in market token)
2. This creates a **second oracle request** on NousOracle with:
   - The same query + verification criteria
   - The additional context: "This is a dispute of a prior judgment. Prior judgment: [KEPT/BROKEN/PARTIAL at X%]. Challenger's reasoning: [provided by challenger]. Re-evaluate independently."
   - `numInfoAgents` doubled (e.g., 6 instead of 3) for broader consensus
   - `rewardAmount` funded by the challenger's dispute stake
3. The second oracle result **overrides** the first. No further appeals in v1.
4. If the dispute changes the outcome: challenger gets their stake back + a reward (funded from the dispute fee pool)
5. If the dispute upholds the original: challenger's stake is forfeited to the dispute fee pool
6. After the dispute resolves (or challenge window expires with no dispute), market finalizes and redemption opens

**Payouts are held during the 48-hour window.** Traders cannot redeem until the market is finalized.

## Reputation & Social Layer

### Promise Profiles

- Every address accumulates a public promise history
- **Promise Score** — see scoring formula below
- On-chain and composable — other protocols can query promise scores via `PromiseReputation.sol`

### Scoring Formula

```
Promise Score = weighted_sum(resolution_percentages) / total_weight

Where for each resolved promise:
  - resolution_percentage = 100 (KEPT), 0 (BROKEN), or X (PARTIALLY_KEPT at X%)
  - weight = bond_size_in_eth * time_decay_factor
  - time_decay_factor = 0.95 ^ months_since_resolution (half-life ~14 months)
```

This means:
- Larger bonds count more (putting up 10 ETH and keeping your promise matters more than 0.01 ETH)
- Recent promises matter more than old ones (exponential decay)
- Partial fulfillment is reflected proportionally
- Score ranges from 0 to 100

A new address with no promises has **no score** (null), not 0 or 100. Protocols consuming the score decide how to treat unscored addresses.

### Promise Categories

- **Personal** — *"I will run a marathon by December"*
- **Project/Protocol** — *"We will ship cross-chain bridging by Q4"*
- **Public Figure** — *"The mayor pledged to reduce emissions by 20%"* (third-party, no maker reputation impact)
- **Inter-party** — *"I promise to deliver the design files to @alice by Friday"*

### Social Mechanics

- **Endorse** — equivalent to buying YES shares. "Endorsing" is a UI concept, not a separate contract mechanism. The frontend shows who bought YES with a public endorsement message attached (stored on IPFS, linked via an event).
- **Challenge** — equivalent to buying NO shares, with the option to attach a public reasoning message
- **Discovery** — promise feeds, trending promises, most-watched markets

### Reputation Composability

Other dApps can query promise scores via `PromiseReputation.sol`:
- `getPromiseScore(address) -> (uint256 score, uint256 totalPromises, bool hasScore)`
- DAOs require minimum promise score for governance roles
- Lending protocols offer better rates to high-score addresses
- Hiring/bounty platforms surface high-reputation builders

## Architecture & Nous Integration

### Smart Contract Stack

```
PromiseMarket.sol          -- Core: create promises, manage bonds, trigger resolution, settle
PromiseMarketAMM.sol       -- LMSR AMM for YES/NO share trading (ERC-1155 shares)
PromiseReputation.sol      -- On-chain promise history and score calculations
PromiseMarket integrates -> NousOracle.sol (existing, unmodified)
```

### Oracle Request Parameters

**All oracle requests use ETH for both `rewardToken` and `bondToken`**, regardless of the promise market's denomination token. This simplifies the integration — the PromiseMarket contract maintains a small ETH reserve (funded by creation fees and a portion of trading fees from ETH-denominated markets) specifically for oracle requests. For ERC-20-denominated markets, the creation fee includes a small ETH surcharge to fund future oracle resolution.

When `triggerResolution()` is called, PromiseMarket creates an oracle request with these parameters:

| Parameter | Value | Funded By |
|---|---|---|
| `rewardAmount` | Fixed protocol parameter, e.g. 0.01 ETH | Protocol's ETH reserve (from creation fee surcharges) |
| `rewardToken` | `address(0)` (ETH) | — |
| `bondAmount` | Set to match oracle's standard agent bond (e.g., 0.005 ETH) | Agents stake their own bonds |
| `bondToken` | `address(0)` (ETH) | — |
| `numInfoAgents` | 3 for standard resolution, 6 for dispute resolution | — |
| `deadline` | `block.timestamp + COMMIT_WINDOW` (e.g., 24 hours) | — |
| `query` | Structured query (see below) | — |
| `specifications` | Judging guidelines (see below) | — |
| `requiredCapabilities` | Domain-relevant capabilities from promise category (see note below) | — |

### Oracle Query Format

**Query:**
> "Evaluate whether the following promise was kept. Promise: '[promise text]'. Verification Criteria: '[verification criteria]'. Deadline: [date]. Evidence submitted: [IPFS links]. Evaluate strictly against the stated verification criteria. You MUST return your answer in the following exact format on the first line: RESULT:KEPT or RESULT:BROKEN or RESULT:PARTIALLY_KEPT:XX where XX is a percentage 0-100. Follow with your detailed reasoning."

**Specifications:**
> "Evaluate against the maker's stated verification criteria, not subjective interpretation. Weigh verifiable evidence over unsubstantiated claims. Consider partial fulfillment and return a percentage. When spirit and letter of the criteria conflict, prioritize the letter (criteria were explicitly stated). Your first line MUST be the structured RESULT line."

**Required Capabilities:** The `requiredCapabilities` field is set with domain-relevant capabilities (e.g., `domains: ["software", "open-source"]` for code-related promises). **Note:** This is advisory, not enforced on-chain. NousOracle stores capabilities on the request but does not prevent agents without matching capabilities from committing. The filtering happens off-chain — agents are expected to self-select based on their expertise. In practice, the economic incentives (bonding + slashing) discourage unqualified agents from participating in domains where they're likely to lose.

### Answer Encoding & Parsing

The oracle's `finalAnswer` is stored as `bytes` on-chain. PromiseMarket parses it as follows:

1. The `finalAnswer` bytes are the UTF-8 encoded judge output (already the case in Nous — the judge writes a string, it gets stored as bytes)
2. `settleMarket()` parses the first line of the UTF-8 string, looking for the prefix pattern:
   - `RESULT:KEPT` -> outcome = KEPT, percentage = 100
   - `RESULT:BROKEN` -> outcome = BROKEN, percentage = 0
   - `RESULT:PARTIALLY_KEPT:XX` -> outcome = PARTIALLY_KEPT, percentage = XX (clamped to 0-100)
3. **Malformed response handling:** If the first line doesn't match any expected pattern, the market enters a `RESOLUTION_FAILED` state. In this state:
   - A new resolution can be triggered (retry with a fresh oracle request)
   - After 3 failed attempts, the market can be emergency-cancelled (all shares refunded at cost basis, maker bond returned minus fees)

### Data Flow

```
1. Promise created
   -> promise text + verification criteria + evidence stored on IPFS
   -> IPFS CIDs stored on-chain in promise struct
   -> Judge pool snapshot taken from NousOracle

2. Deadline passes, triggerResolution() called
   -> PromiseMarket calls NousOracle.createRequest()
   -> Oracle agents commit (off-chain, ~24h)
   -> Oracle agents reveal (off-chain, ~24h)
   -> Judge evaluates and submits aggregation (off-chain)

3. Oracle reaches Finalized state
   -> Anyone calls settleMarket()
   -> PromiseMarket reads finalAnswer via NousOracle.getResolution()
   -> Parses RESULT line, sets market outcome + percentage
   -> settleMarket() also calls NousOracle.distributeRewards() to pay oracle agents
      (if already called by someone else, this is a no-op since the oracle
       transitions to Distributed phase and subsequent calls revert)
   -> 48h challenge window begins

4. Challenge window expires (or dispute resolves)
   -> Market finalized
   -> Share holders redeem via redeemShares()
   -> Maker bond distributed per outcome
   -> Reputation updated in PromiseReputation.sol
```

### IPFS Pinning Strategy

All IPFS content (promise text, evidence, oracle answers) is pinned via the existing Nous IPFS infrastructure. PromiseMarket frontend also pins promise content independently as a redundancy layer. If IPFS content is unavailable at resolution time, agents can note this in their evaluation — a promise with no retrievable evidence is harder to judge as "kept."

### What We Build vs. What Nous Provides

| Nous (existing, unmodified) | Promise Markets (new) |
|---|---|
| Oracle request/response lifecycle | Promise creation & management |
| Commit-reveal-judge-distribute | LMSR AMM for YES/NO trading |
| IPFS storage for answers | ERC-1155 share tokens |
| Agent bonding & slashing | Market settlement + answer parsing |
| Judge selection & synthesis | Reputation scoring |
| Multi-agent evaluation | Evidence submission system |
| | Dispute flow (second oracle request) |
| | Frontend for browsing/trading |

## Monetization

### Revenue Streams

| Stream | Mechanism | Take Rate |
|---|---|---|
| Trading fees | Fee on every YES/NO share trade | 2% per trade |
| Promise creation fee | Flat fee at creation | 0.5% of bond (min 0.001 ETH) |
| Resolution funding | From accumulated trading fees, funds oracle rewards | Per-resolution cost ~0.01 ETH |
| Dispute fee | Fee to challenge a ruling (partial refund if successful) | Flat (e.g. 0.05 ETH) |

### Money Flow Example

```
Maker creates promise with 1 ETH bond
  -> 0.005 ETH creation fee -> protocol treasury
  -> 0.2 ETH allocated to AMM liquidity (from bond)
  -> 0.795 ETH held in bond escrow

Market trades $50,000 total volume
  -> $1,000 in trading fees -> fee pool
  -> ~$10 reserved for oracle resolution cost

Resolution triggered
  -> Oracle reward (0.01 ETH) paid from fee pool
  -> Oracle cycle runs (24-72h)

Market settles, 48h challenge window, then finalized
  -> Winners redeem shares
  -> Maker bond returned/forfeited per outcome
  -> AMM liquidity returned to maker (if kept) or distributed (if broken)
```

### Growth Flywheel

```
More promises -> more trading volume -> more fees
     ^                                    |
     |                                    v
More users <- interesting markets <- liquidity deepens
```

### Future Revenue Opportunities

- **API access** — other protocols pay to query promise scores/reputation data
- **White-label** — DAOs deploy branded Promise Markets instances
- **Data licensing** — historical resolution data for AI training/research
- **Sponsored promises** — protocols make bonded public commitments as accountability-marketing ("We promise 10% APY for 6 months" — break it and you lose money + reputation)
