# BLOKC Rewards System — Architecture & Flow

## Overview

The BLOKC Rewards system enables automated, AI-scored reward distribution to contributors while enforcing a human-in-the-loop approval gate. An AI agent evaluates contributor work off-chain, proposes on-chain distributions, and after two designated signers approve, BLOKC tokens are transferred to per-contributor time-locked vaults. The entire flow is auditable on-chain with off-chain monitoring for anomaly detection.

### Key properties

- **AI proposes, humans approve** — the AI cannot unilaterally move tokens
- **2-of-N multisig gate** — at least two signers must approve every distribution
- **Time-locked vesting** — tokens are locked in contributor vaults until May 1, 2027
- **Deterministic accounts** — each contributor has exactly one knowable vault address
- **Pre-fund capable** — tokens can be sent to a vault before it is deployed
- **On-chain ledger** — every proposal, approval, and execution is permanently recorded
- **Off-chain monitoring** — a Cloudflare worker watches for anomalies and sends pre-distribution reports
- **Defense-in-depth** — `MIN_THRESHOLD` constant (2) prevents even the DAO from dropping to single-signer approval

---

## System Architecture

```
                         OFF-CHAIN                              ON-CHAIN
  ┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
  │                                      │    │                                      │
  │  ┌────────────────────┐              │    │   BLOKC ERC20Votes Token             │
  │  │ Data Sources       │              │    │   (governance-enabled)               │
  │  │ - Discord messages  │              │    │        │                             │
  │  │ - GitHub PRs       │              │    │        │ fund                        │
  │  │ - X/Farcaster posts│              │    │        ▼                             │
  │  │ - On-chain activity │              │    │  ┌──────────────────────┐            │
  │  └────────┬───────────┘              │    │  │  BLOKCDistributor    │            │
  │           │                          │    │  │                      │            │
  │           ▼                          │    │  │  - holds BLOKC pool  │            │
  │  ┌────────────────────┐              │    │  │  - propose (AI only) │            │
  │  │ AI Scoring Engine  │              │    │  │  - approve (signers) │            │
  │  │ (LLM agent)        │              │    │  │  - execute (anyone)  │            │
  │  │                    │              │    │  │  - cancel (AI only)  │            │
  │  │ - evaluates work   │   propose()  │    │  │  - MIN_THRESHOLD = 2 │            │
  │  │ - computes amounts  │─────────────▶│────▶│  └──────────┬───────────┘            │
  │  │ - has its own EOA   │              │    │             │                        │
  │  └────────┬───────────┘              │    │             │ predictContributor      │
  │           │                          │    │             │ Account()               │
  │           │ emits event              │    │             ▼                        │
  │           ▼                          │    │  ┌──────────────────────┐            │
  │  ┌────────────────────┐              │    │  │  BLOKCContributor    │            │
  │  │ Cloudflare Worker  │              │    │  │  Factory             │            │
  │  │                    │              │    │  │                      │            │
  │  │ - listens to       │              │    │  │  - CREATE2 clones    │            │
  │  │   Distribution     │              │    │  │  - deterministic     │            │
  │  │   Proposed events  │              │    │  │    addresses         │            │
  │  │ - generates report │              │    │  │  - self-deploy only  │            │
  │  │ - flags anomalies  │              │    │  │  - idempotent        │            │
  │  │ - sends to Slack / │              │    │  └──────────┬───────────┘            │
  │  │   Discord / email  │              │    │             │                        │
  │  └────────────────────┘              │    │             │ deploy clone            │
  │                                      │    │             ▼                        │
  │  ┌────────────────────┐              │    │  ┌──────────────────────┐            │
  │  │ Human Signers (2)  │              │    │  │  BLOKCContributor    │            │
  │  │                    │  approve()   │    │  │  Account (per user)  │            │
  │  │ - review report    │─────────────▶│────▶│  │                      │            │
  │  │ - sign on-chain    │              │    │  │  - time-locked vault │            │
  │  └────────────────────┘              │    │  │  - unlocks May 2027  │            │
  │                                      │    │  │  - governance votes  │            │
  │                                      │    │  │    delegated back    │            │
  │                                      │    │  └──────────────────────┘            │
  └──────────────────────────────────────┘    └──────────────────────────────────────┘
```

---

## Contracts

### 1. BLOKC ERC20Votes Token

**Type:** External dependency (canonical governance token)

The `$BLOKC` token is an ERC20 with governance extensions (ERC20Votes). It supports:
- Standard ERC20 transfers, approvals, and allowances
- On-chain vote delegation via `delegate(address)`
- Historical vote tracking via checkpoints
- EIP-712 typed signatures for gasless delegation

The factory and distributor are bound to this token address at deployment and reference it as an immutable address.

### 2. BLOKCContributorAccount

**File:** `src/contracts/BLOKCContributorAccount.sol`

A per-contributor time-locked vault deployed as an EIP-1167 minimal proxy clone. Each account:

- **Holds `$BLOKC`** for exactly one contributor
- **Locks tokens** until a single unlock timestamp (May 1, 2027 00:00:00 UTC for production)
- **Delegates voting power** back to the contributor on initialization — so locked tokens still count toward governance
- **Allows the contributor** to withdraw any amount to any address after unlock
- **Prevents anyone else** from withdrawing via the `onlyContributor` modifier
- **Allows recovery** of non-BLOKC ERC20 tokens mistakenly sent to the account (available immediately, not subject to the lock)

#### State (immutable after initialization)

| Variable | Type | Description |
|---|---|---|
| `token` | `address` | The canonical BLOKC token address |
| `contributor` | `address` | The contributor who owns this account |
| `unlockTimestamp` | `uint64` | Unix timestamp when tokens become withdrawable |

#### Key functions

| Function | Access | Description |
|---|---|---|
| `initialize(contributor, token, unlockTimestamp)` | Factory only | One-shot setup, delegates votes |
| `withdraw(to, amount)` | Contributor only, after unlock | Partial withdrawal to any address |
| `withdrawTokensAll()` | Contributor only, after unlock | Sweep full balance to contributor |
| `recoverERC20(token, to, amount)` | Contributor only, any time | Recover non-BLOKC tokens |
| `balanceOf()` | Public view | Current BLOKC balance |
| `isUnlocked()` | Public view | Whether unlock has occurred |
| `timeUntilUnlock()` | Public view | Seconds remaining until unlock |

### 3. BLOKCContributorFactory

**File:** `src/contracts/factory/BLOKCContributorFactory.sol`

A permissionless factory that deterministically deploys one `BLOKCContributorAccount` clone per contributor.

#### Design decisions

- **CREATE2 with salt = contributor address:** `salt = bytes32(uint256(uint160(contributor)))`. This means every wallet maps to exactly one predictable account address.
- **EIP-1167 minimal proxies:** Each clone costs ~55k gas to deploy instead of ~1M+ for a full deployment. All clones delegate execution to a single shared implementation contract.
- **Self-deploy only:** `createContributorAccount()` always deploys for `msg.sender`. No one can deploy an account on someone else's behalf.
- **Idempotent:** Calling `createContributorAccount()` twice returns the same address. The registry never duplicates entries.
- **Immutable configuration:** `token`, `implementation`, and `unlockTimestamp` are set at construction and can never be changed. To change the unlock date, deploy a new factory.

#### State

| Variable | Type | Mutability | Description |
|---|---|---|---|
| `token` | `address` | immutable | Canonical BLOKC token |
| `implementation` | `address` | immutable | Account implementation (clone target) |
| `unlockTimestamp` | `uint64` | immutable | Shared unlock time for all accounts |
| `accounts` | `address[]` | append-only | Registry of all deployed accounts |
| `holdsAccount` | `mapping(address => bool)` | mutable | Whether contributor has an account |
| `accountOf` | `mapping(address => address)` | mutable | Deployed account address per contributor |

#### Key functions

| Function | Description |
|---|---|
| `createContributorAccount()` | Deploy (or return) caller's own account |
| `predictContributorAccount(contributor)` | Compute the deterministic address for any contributor |
| `getAccounts(offset, limit)` | Paginated registry read |
| `getAccountOf(contributor)` | Look up deployed account address |

#### Pre-fund pattern

The factory's `predictContributorAccount()` returns the deterministic CREATE2 address for any contributor, whether or not the account has been deployed yet. Tokens sent to this address sit there and are automatically "captured" when the clone is deployed at that address. This means:

1. The DAO (or BLOKCDistributor) can send BLOKC to `predictContributorAccount(alice)` before Alice ever interacts with the chain
2. When Alice (or anyone) calls `createContributorAccount()`, the clone is deployed at exactly that address
3. The clone immediately holds whatever tokens were sitting at the address
4. No special "claim" step is needed — the tokens are just there

The `BLOKCDistributor` uses this pattern exclusively. It never deploys clones itself (which would break the factory's idempotency).

### 4. BLOKCDistributor

**File:** `src/contracts/BLOKCDistributor.sol`

The core reward distribution contract. AI proposes, humans approve, tokens flow.

#### Three-role access control

```
                    ┌─────────────┐
                    │    OWNER    │  (DAO multisig)
                    │             │
                    │ add/remove  │
                    │ signers     │
                    │ update      │
                    │ proposer    │
                    │ update      │
                    │ threshold   │
                    │ recover     │
                    │ tokens      │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
     ┌────────────┐ ┌────────────┐ ┌────────────┐
     │ PROPOSER   │ │  SIGNER 1  │ │  SIGNER 2  │
     │ (AI wallet)│ │  (human)   │ │  (human)   │
     │            │ │            │ │            │
     │ propose    │ │ approve    │ │ approve    │
     │ cancel     │ │            │ │            │
     └────────────┘ └────────────┘ └────────────┘
              │            │            │
              │            └─────┬──────┘
              │                  │
              │           ┌──────▼──────┐
              │           │  EXECUTOR   │  (permissionless)
              │           │             │
              └──────────▶│  execute    │
                          │  (anyone)   │
                          └─────────────┘
```

**The proposer cannot execute.** The signers cannot propose. The owner can manage configuration but cannot propose, approve, or execute distributions. No single role can move tokens.

#### State

| Variable | Type | Mutability | Description |
|---|---|---|---|
| `token` | `address` | immutable | Canonical BLOKC token |
| `factory` | `BLOKCContributorFactory` | immutable | For predicting account addresses |
| `MIN_THRESHOLD` | `uint256` | constant (2) | Absolute floor on approval threshold |
| `proposer` | `address` | mutable | AI wallet (updatable by owner) |
| `owner` | `address` | mutable | Admin address (DAO multisig) |
| `threshold` | `uint256` | mutable | Approvals needed (≥ MIN_THRESHOLD) |
| `signers` | `address[]` | mutable | List of authorized approvers |
| `isSigner` | `mapping(address => bool)` | mutable | Quick signer lookup |
| `distributions` | `mapping(uint256 => Distribution)` | mutable | Per-epoch proposal data |
| `approvals` | `mapping(uint256 => mapping(address => bool))` | mutable | Per-epoch, per-signer approvals |

#### Distribution struct

```solidity
struct Distribution {
    address[] contributors;   // Contributor addresses
    uint256[] amounts;         // Reward per contributor (in wei)
    uint256 approvalCount;     // How many signers have approved
    bool executed;             // True after tokens transferred
    uint256 proposedAt;        // Block timestamp of proposal
}
```

#### Core functions

**`proposeDistribution(epochId, contributors[], amounts[])`**
- Caller: AI proposer only (`onlyProposer`)
- Validates: epochId ≠ 0, arrays non-empty and equal length, no zero addresses, no zero amounts, epoch not already proposed
- Stores the full distribution in contract storage (acts as an on-chain ledger)
- Emits `DistributionProposed(epochId, totalAmount, contributors, amounts)`

**`approveDistribution(epochId)`**
- Caller: authorized signers only (`onlySigner`)
- Validates: distribution exists, not yet executed, signer hasn't already approved
- Increments approval count, tracks per-signer approval
- Does NOT auto-execute (gas costs don't land on the last signer)
- Emits `DistributionApproved(epochId, signer, approvalCount)`

**`executeDistribution(epochId)`**
- Caller: anyone (permissionless)
- Validates: distribution exists, not executed, `approvalCount ≥ threshold`, contract has sufficient BLOKC balance
- Sets `executed = true` BEFORE transfers (Checks-Effects-Interactions)
- Iterates contributors: `factory.predictContributorAccount(c)` → `token.safeTransfer(account, amount)`
- Emits `DistributionExecuted(epochId, totalAmount, contributorCount)`

**`cancelDistribution(epochId)`**
- Caller: AI proposer only (`onlyProposer`)
- Validates: distribution exists, not yet executed
- Clears all approvals for the epoch and deletes the distribution
- Allows re-proposal for the same epoch
- Emits `DistributionCancelled(epochId)`

#### Admin functions (owner only)

| Function | Description |
|---|---|
| `addSigner(address)` | Add a new signer to the authorized set |
| `removeSigner(address)` | Remove a signer (reverts if it would drop signers below threshold) |
| `updateProposer(address)` | Rotate the AI wallet (key rotation / model upgrade) |
| `updateThreshold(uint256)` | Change approval threshold (reverts if below `MIN_THRESHOLD` or above signer count) |
| `updateOwner(address)` | Transfer ownership |
| `recoverTokens(token, to, amount)` | Sweep any ERC20 (including BLOKC dust) to any address |

#### Events (for off-chain monitoring)

| Event | Indexed Parameters | Purpose |
|---|---|---|
| `DistributionProposed` | `epochId`, `totalAmount` | Cloudflare worker trigger — generates pre-distribution report |
| `DistributionApproved` | `epochId`, `signer` | Tracks approval progress |
| `DistributionExecuted` | `epochId` | Confirms token movement complete |
| `DistributionCancelled` | `epochId` | Alerts monitoring that a proposal was withdrawn |
| `SignerAdded` / `SignerRemoved` | `signer` | Audit trail for signer set changes |
| `ProposerUpdated` | `oldProposer`, `newProposer` | Audit trail for AI key rotation |
| `ThresholdUpdated` | `oldThreshold`, `newThreshold` | Audit trail for threshold changes |
| `OwnerUpdated` | `oldOwner`, `newOwner` | Audit trail for ownership transfer |
| `TokensRecovered` | `token`, `to` | Audit trail for token recovery |

#### Security guarantees

| Attack vector | Protection |
|---|---|
| Attacker proposes | `onlyProposer` modifier — attacker is not the AI wallet |
| Attacker approves | `onlySigner` modifier — attacker is not in the signer set |
| Attacker executes without approvals | `approvalCount ≥ threshold` check |
| Attacker double-executes | `executed` flag — CEI pattern marks executed before transfers |
| Attacker double-approves | `approvals[epochId][signer]` tracking per signer |
| Attacker calls admin functions | `onlyOwner` modifier — attacker is not the DAO multisig |
| Compromised proposer + 1 signer | `threshold = 2` minimum — need 2 independent signers |
| DAO tries to drop threshold to 1 | `MIN_THRESHOLD = 2` constant — immutable bytecode-level floor |
| Reentrancy during execute | CEI pattern: `executed = true` set before any transfers. Reentrant call hits `AlreadyExecuted` |
| Malicious token callback | Same CEI protection — reentrant call reverts, outer transaction reverts, state unchanged |
| Implementation direct initialization | `_disableInitializers()` in constructor — only EIP-1167 clones can be initialized |
| ETH forced into contracts | No `receive()` or `fallback()` on any contract |
| Factory clone collision | CREATE2 with unique salt per contributor — factory checks its own registry before deploying |

---

## Full Lifecycle: Weekly Distribution

### Step-by-step

#### 1. AI analyzes contributor activity (off-chain)

The AI agent ingests data from multiple sources:

- **Discord:** messages, help in support channels, community management
- **GitHub:** PRs opened/merged, code reviews, issues filed
- **X / Farcaster:** educational threads, protocol promotion, community building
- **On-chain:** governance voting participation, liquidity provision, protocol usage

The AI evaluates each contribution across dimensions such as quality, relevance, impact, and originality. Based on these assessments, it computes a reward amount (in BLOKC wei) for each contributor who was active that week.

#### 2. AI proposes distribution (on-chain)

The AI, using its dedicated EOA wallet, calls:

```
BLOKCDistributor.proposeDistribution(
    epochId,        // e.g., 12 (week number)
    [0xAlice, 0xBob, 0xCharlie, ...],
    [3200e18, 2100e18, 1800e18, ...]
)
```

This stores the full distribution on-chain and emits `DistributionProposed`. The AI cannot unilaterally move tokens — this is purely a proposal.

#### 3. Cloudflare worker generates report (off-chain)

A Cloudflare worker (or equivalent edge function) listens for `DistributionProposed` events via a WebSocket or polling connection to an RPC node. On each event, it:

1. Decodes the `contributors[]` and `amounts[]` arrays from the event data
2. Resolves contributor addresses to known identities (ENS, stored mappings)
3. Computes summary statistics (total distributed, per-contributor share, top recipients)
4. Checks for anomalies:
   - Any single amount exceeding a configurable threshold (e.g., > 2500 BLOKC)
   - Any single contributor receiving > 30% of the total
   - New contributors appearing for the first time
   - Significant deviation from historical distribution patterns
5. Generates a formatted report:

```
Epoch #12 Distribution Report
─────────────────────────────
Total: 10,000 BLOKC across 8 contributors

0xAlice   — 3,200 BLOKC (32%)  ← high-value technical content (PR #42)
0xBob     — 2,100 BLOKC (21%)  ← community management
0xCharlie — 1,800 BLOKC (18%)  ← educational thread on X
...

⚠️  Flags:
  - 0xAlice amount (3,200) exceeds typical max of 2,500 — manual review recommended
  - 0xDave is a new contributor (first distribution)
```

6. Sends the report to the team via Slack, Discord, or email

#### 4. Signers review and approve (human-in-the-loop)

The two designated signers review the report. If everything looks correct:

- Signer 1 calls `approveDistribution(epochId)`
- Signer 2 calls `approveDistribution(epochId)`

If something looks off (anomalous amount, wrong contributor, suspected AI error), the team asks the AI operator to cancel and re-propose:

- AI calls `cancelDistribution(epochId)` — clears the proposal and all approvals
- AI re-computes corrected amounts
- AI calls `proposeDistribution(epochId, correctedContributors, correctedAmounts)`
- Signers review the corrected report and approve

#### 5. Execution (permissionless)

Once `approvalCount ≥ threshold`, anyone can call `executeDistribution(epochId)`. In practice, this will likely be done by:

- A keeper bot that monitors for fully-approved distributions and executes them
- The last signer, if they choose to pay the gas
- Any team member or automated script

The execution:
1. Verifies the distributor has enough BLOKC to cover the full distribution
2. Marks the distribution as executed (CEI — effects before interactions)
3. For each contributor, resolves `factory.predictContributorAccount(contributor)` and transfers `amount` BLOKC to that address
4. Emits `DistributionExecuted`

#### 6. Tokens vest in contributor accounts

Tokens are now in each contributor's deterministic vault address. If the contributor has already deployed their account (via `factory.createContributorAccount()`), the tokens are held by the clone contract and visible immediately. If they haven't deployed yet, the tokens sit at the bare CREATE2 address and will be captured when the clone is deployed.

The tokens are **locked** until the unlock timestamp (May 1, 2027 00:00:00 UTC). Throughout the lock period, voting power is delegated back to the contributor, so locked tokens still count toward governance.

After unlock, the contributor calls `withdraw(to, amount)` or `withdrawTokensAll()` to move tokens to any address.

---

## Account Storage Model

### Deterministic addressing

Every contributor maps to exactly one account address, computed as:

```
salt = bytes32(uint256(uint160(contributor)))
address = CREATE2(
    deployer = factory,
    salt     = salt,
    initCode = keccak256(EIP-1167 proxy bytecode pointing to implementation)
)
```

This means:
- Alice's account address can be computed before Alice ever interacts with the chain
- The address will never change — it's cryptographically bound to Alice's wallet
- There is exactly one account per contributor, forever

### Account registry

The factory maintains an append-only registry of all deployed accounts:

```
accounts[]       — ordered list (index 0, 1, 2, ...)
accountOf[addr]  — quick lookup: contributor → account address
holdsAccount[addr] — boolean: does this contributor have an account?
```

The registry is idempotent — calling `createContributorAccount()` twice for the same contributor does not add a duplicate entry. The registry can be read via paginated queries (`getAccounts(offset, limit)`) to avoid gas/return-size issues as the registry grows.

### BLOKC flow into accounts

There are two paths for BLOKC to enter a contributor account:

1. **DAO direct transfer:** The DAO treasury calls `token.transfer(predictedAddress, amount)`
2. **BLOKCDistributor distribution:** The distributor sends tokens to `factory.predictContributorAccount(contributor)` during `executeDistribution()`

In both cases, the receiving address is the deterministic CREATE2 address. If the account exists (clone deployed), the tokens are held by the clone. If not, they sit at the bare address and are captured when the clone is deployed. This is the "pre-fund" pattern — tokens arrive before the contributor ever touches the chain.

### Why the distributor doesn't deploy accounts

The distributor deliberately does NOT deploy contributor accounts via `Clones.cloneDeterministic()`. If it did:

1. The distributor would deploy a clone at Alice's predicted address
2. The factory would have no record of it (the factory's `accountOf` mapping wouldn't be updated)
3. If Alice later called `factory.createContributorAccount()`, the factory would try `cloneDeterministic()` at the same address — which would revert because the address is already occupied by code
4. Alice would be permanently unable to use the factory for her account

By only sending tokens to predicted addresses (without deploying anything), the distributor remains a pure funding layer and the factory remains the single source of truth for account deployment.

---

## AI Scoring System

### Design

The AI agent is an off-chain system with its own EOA wallet. It is the only address authorized to call `proposeDistribution()` and `cancelDistribution()` on the `BLOKCDistributor`.

### Scoring dimensions

The AI evaluates contributor work across four dimensions:

| Dimension | What it measures | Example |
|---|---|---|
| **Quality** | Depth, correctness, and effort of the contribution | A well-researched technical thread vs. a one-line reply |
| **Relevance** | Alignment with BLOK Capital's goals and priorities | Protocol improvement proposals vs. off-topic discussion |
| **Impact** | Reach, engagement, and downstream effects | PR that unlocks a new feature vs. typo fix |
| **Originality** | Net-new contribution vs. rehash of existing work | Original research vs. reposting known information |

### Scoring to amount conversion

The AI directly computes BLOKC amounts (not abstract scores). This gives the AI flexibility:

- High-activity weeks get larger total distributions
- Low-activity weeks don't waste a fixed pool
- Individual contributions are valued absolutely, not relatively

The AI is trusted to be fair, but the 2-of-N signer gate and monitoring system provide checks against errors or manipulation.

### AI wallet management

The AI's wallet address is stored as the `proposer` in the `BLOKCDistributor`. The owner (DAO multisig) can rotate this address via `updateProposer()` for:

- Key rotation (regular security practice)
- Model upgrade (new AI system with a new wallet)
- Emergency revocation (if the AI key is compromised)

The old proposer immediately loses the ability to propose or cancel distributions.

---

## Monitoring System

### Architecture

The monitoring system consists of a Cloudflare worker (or equivalent edge function) that:

1. **Connects to an RPC node** (e.g., Alchemy, Infura, or a self-hosted node) via WebSocket or HTTP polling
2. **Listens for events** from the `BLOKCDistributor` contract:
   - `DistributionProposed(epochId, totalAmount, contributors, amounts)` — primary trigger
   - `DistributionCancelled(epochId)` — alert that a proposal was withdrawn
   - `SignerAdded(signer)` / `SignerRemoved(signer)` — audit signer set changes
   - `ProposerUpdated(oldProposer, newProposer)` — audit AI key rotation
   - `ThresholdUpdated(oldThreshold, newThreshold)` — audit threshold changes
3. **Processes each event** into a human-readable report
4. **Sends reports** to configured channels (Slack webhook, Discord webhook, email)

### Anomaly detection rules

The worker applies configurable rules to flag suspicious distributions:

| Rule | Threshold | Action |
|---|---|---|
| Single amount too high | > 2,500 BLOKC | Flag for manual review |
| Single contributor share | > 30% of total | Flag for manual review |
| New contributor | First-ever distribution | Informational flag |
| Total distribution spike | > 2× weekly average | Flag for manual review |
| Rapid re-proposals | Cancel + re-propose within 5 minutes | Informational (may indicate AI error) |

### Report format

```
┌─────────────────────────────────────────────────────────────┐
│               BLOKC Distribution Report                     │
│               Epoch #12 — June 16, 2026                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Total: 10,000 BLOKC across 8 contributors                  │
│                                                             │
│  Distribution:                                              │
│  ┌──────────────────┬──────────┬──────┬──────────────────┐  │
│  │ Contributor      │ Amount   │ Share│ Notes            │  │
│  ├──────────────────┼──────────┼──────┼──────────────────┤  │
│  │ 0xAlice...       │ 3,200    │ 32%  │ Technical content│  │
│  │ 0xBob...         │ 2,100    │ 21%  │ Community mgmt   │  │
│  │ 0xCharlie...     │ 1,800    │ 18%  │ Educational posts│  │
│  │ ...              │ ...      │ ...  │ ...              │  │
│  └──────────────────┴──────────┴──────┴──────────────────┘  │
│                                                             │
│  ⚠️  Flags:                                                 │
│  • 0xAlice (3,200 BLOKC) exceeds max threshold (2,500)     │
│  • 0xDave is a new contributor (first distribution)        │
│                                                             │
│  Status: Pending approvals (0/2)                            │
│  Proposed by: 0xAI... (AI Proposer)                        │
│  Transaction: 0x...                                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### After report delivery

1. **No flags:** Signers proceed to approve on-chain
2. **Flags present:** Team investigates — checks the AI's reasoning, reviews the contributor's actual work, confirms or adjusts amounts
3. **If correction needed:** AI operator is asked to cancel and re-propose
4. **If everything is fine:** Signers approve despite the flags (flags are informational, not blocking)

---

## Deployment

### Contracts to deploy (in order)

1. **BLOKC ERC20Votes Token** — External dependency; already deployed for production
2. **BLOKCContributorAccount** (implementation) — Deployed once; its constructor calls `_disableInitializers()` so only clones can be initialized
3. **BLOKCContributorFactory** — Bound to token, implementation, and unlock timestamp (May 1, 2027). Immutable — to change unlock, deploy a new factory
4. **BLOKCDistributor** — Bound to token, factory, AI proposer address, owner (DAO multisig), initial signer set (2 addresses), and threshold (2)

### Environment variables

```bash
# Required for deploy script
BLOKC_TOKEN=0x...              # Canonical BLOKC ERC20Votes token
AI_PROPOSER=0x...              # AI agent's EOA wallet
DISTRIBUTOR_OWNER=0x...        # DAO multisig address
DISTRIBUTOR_SIGNER_1=0x...     # First designated signer
DISTRIBUTOR_SIGNER_2=0x...     # Second designated signer
PRIVATE_KEY=0x...              # Deployer private key
RPC_URL=https://...            # RPC URL for target chain
API_KEY_ETHERSCAN=...          # For contract verification
FIRST_CONTRIBUTOR=0x...        # (Optional) Smoke test address
```

### Deploy command

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $API_KEY_ETHERSCAN
```

### Post-deployment steps

1. **Fund the distributor:** Transfer BLOKC from the DAO treasury to the `BLOKCDistributor` address via a standard ERC20 transfer
2. **Verify all contracts** on Etherscan (or equivalent block explorer)
3. **Configure the Cloudflare worker** with:
   - RPC endpoint
   - `BLOKCDistributor` contract address
   - `DistributionProposed` event signature
   - Slack/Discord webhook URLs
   - Anomaly detection thresholds
4. **Test the full flow** on the deployed chain:
   - AI proposes epoch 1
   - Cloudflare worker generates report
   - Signers approve
   - Execute
   - Verify tokens arrived in contributor accounts

---

## Test Suite

### Coverage

| Type | Files | Tests | What it covers |
|---|---|---|---|
| Unit | `test/unit/BLOKCContributorAccount.t.sol` | 32 | Account initialization, withdrawals, recovery, views |
| Unit | `test/unit/BLOKCContributorFactory.t.sol` | 22 | Factory deployment, CREATE2, registry, pagination, idempotency |
| Unit | `test/unit/BLOKCDistributor.t.sol` | 74 | Constructor, propose, approve, execute, cancel, admin, views |
| Integration | `test/integration/Lifecycle.t.sol` | 3 | Multi-contributor, pre-fund, top-up flows |
| Integration | `test/integration/Reentrancy.t.sol` | 3 | Malicious ERC20 reentrancy on account contract |
| Integration | `test/integration/DistributorLifecycle.t.sol` | 6 | Multi-epoch, proposer rotation, signer rotation, cancel-re-propose, threshold changes, pre-fund |
| Integration | `test/integration/DistributorReentrancy.t.sol` | 1 | Malicious BLOKC reentrancy on distributor (CEI protection) |
| Fuzz | `test/fuzz/AccountFuzz.t.sol` | 6 | Withdrawal amounts, unlock boundary, recovery |
| Fuzz | `test/fuzz/FactoryFuzz.t.sol` | 4 | CREATE2 determinism, idempotency, distinct accounts |
| Fuzz | `test/fuzz/DistributorFuzz.t.sol` | 5 | Same-epoch revert, token conservation, approval ordering, cancel-re-propose |
| Invariant | `test/invariant/AccountInvariant.t.sol` | 3 | Balance conservation, immutable config, no withdrawal before unlock |
| Invariant | `test/invariant/FactoryInvariant.t.sol` | 3 | Account stability, ownership backlinks, registry length consistency |
| **Total** | **12 suites** | **162** | |

### Running tests

```bash
forge test                    # All 162 tests
forge test -vvv               # Verbose output
forge test --match-path test/unit/BLOKCDistributor.t.sol  # Distributor only
```

### CI pipeline

```yaml
name: CI
on: [push, pull_request]
env:
  FOUNDRY_PROFILE: ci
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          submodules: recursive
      - uses: foundry-rs/foundry-toolchain@v1
      - run: forge fmt --check
      - run: forge build --sizes
      - run: forge test -vvv
```

---

## Slither Static Analysis

Slither v0.11.5 was run on the full codebase with 96 detectors.

**Result: 22 INFO findings, 0 HIGH, 0 MEDIUM, 0 LOW.**

All findings are either:
- **False positives** (e.g., uninitialized local variable that Solidity defaults to 0)
- **Acknowledged patterns** (e.g., timestamp usage for vesting, calls-in-loop for pure view functions)
- **Dependency noise** (e.g., OZ pragma version variations)

No actionable security issues.

---

## Trail of Bits Code Maturity Assessment

| Category | Rating | Key Evidence |
|---|---|---|
| Arithmetic | Satisfactory (3) | Solidity 0.8.x built-in overflow protection, simple proportional math |
| Auditing | Satisfactory (3) | Rich event coverage, indexed `totalAmount` for gas-efficient filtering, Cloudflare worker integration |
| Access Controls | Strong (4) | Three-role separation (proposer/signer/owner), custom modifiers with specific errors, signer count guard, CEI pattern |
| Complexity | Satisfactory (3) | Focused single-purpose functions, no deep inheritance, low cyclomatic complexity (2-4 per function) |
| Decentralization | Moderate (2) | Owner is a single address (intended: DAO multisig), no on-chain timelock for admin actions |
| Documentation | Strong (4) | Comprehensive NatSpec on all contracts, architectural rationale in dev comments |
| Transaction Ordering | Satisfactory (3) | No MEV opportunities in execute, no slippage needed, timestamp usage is non-critical |
| Low-Level Code | Satisfactory (3) | No assembly, no delegatecall, SafeERC20 for all transfers |
| Testing | Strong (4) | 162 tests across 12 suites, unit + integration + fuzz + invariant + reentrancy, CI with fmt/build/test |
| **Overall** | **Satisfactory (3.2)** | |

---

## Risk Model

### Trust assumptions

| Component | Trusted to... | Gated by... |
|---|---|---|
| AI Proposer | Submit fair reward amounts | 2-of-N signer approval, Cloudflare monitoring, cancel capability |
| Signers (2+) | Review and approve distributions | Must be independent humans; a single compromised signer cannot execute |
| Owner (DAO multisig) | Manage signer set, proposer, threshold | Requires multiple DAO members to sign; `MIN_THRESHOLD` constant prevents threshold dropping to 1 |
| Factory | Deploy correct clones at deterministic addresses | Immutable implementation address, `_disableInitializers()` on implementation, self-deploy only |
| BLOKC Token | Standard ERC20Votes behavior | External dependency (canonical token) |

### Compromise scenarios

| Scenario | Impact | Mitigation |
|---|---|---|
| AI key compromised | Attacker proposes bogus distributions | Signers won't approve; Cloudflare worker flags anomalies; owner rotates proposer |
| 1 signer key compromised | Attacker can approve but not execute | `threshold = 2` — need a second independent signer |
| 2 signer keys compromised | Attacker can approve + execute a drain | Both signers must be compromised simultaneously; owner can remove compromised signers |
| Owner (DAO multisig) compromised | Attacker can reconfigure the system | This requires compromising the DAO multisig itself (3-of-5 or similar); no bytecode-level defense against this |
| AI + 1 signer compromised | Still cannot execute | Need 2 signers — the second independent signer blocks execution |
| AI + 2 signers compromised | Attacker can drain the distributor | All three roles must be compromised simultaneously; owner can remove signers and rotate proposer if detected |

### Recovery paths

| Issue | Recovery |
|---|---|
| AI produces bad distribution | AI cancels and re-proposes |
| AI key lost | Owner rotates `proposer` to new AI wallet |
| Signer key lost | Owner removes old signer, adds replacement |
| Distributor over-funded | Owner calls `recoverTokens()` to sweep excess BLOKC back to treasury |
| Distributor under-funded | DAO transfers more BLOKC to distributor address |
| Factory needs new unlock date | Deploy new factory + new distributor (existing accounts unchanged) |
