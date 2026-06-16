# Blokc V1 Rewards

Contributor rewards system for Blok Capital's v1 protocol — AI-scored, human-approved, on-chain reward distribution with time-locked vesting.

## Overview

The system has three layers:

1. **BLOKCDistributor** — AI proposes reward distributions for each weekly epoch. All designated signers must approve before tokens move. Acts as an on-chain ledger with events for off-chain monitoring.
2. **BLOKCContributorFactory** — Deterministically deploys per-contributor time-locked vaults via CREATE2. One account per wallet address, idempotent, pre-fund capable.
3. **BLOKCContributorAccount** — Per-contributor EIP-1167 minimal proxy clone. Holds `$BLOKC`, locked until May 1 2027. Voting power delegated to contributor during lock.

## Architecture

- **BLOKCDistributor** — AI-proposed, all-signers-must-approve reward distribution. Proposals are recorded on-chain as an immutable ledger. Minimum 2 signers enforced. No single key can move tokens.
- **Contributor Accounts** — Per-contributor, time-locked vaults that hold `$BLOKC` and release the full balance after one unlock timestamp. Implemented as minimal-proxy clones (EIP-1167).
- **Contributor Factory** — Deterministically deploys Contributor Accounts via CREATE2 (one account per contributor), using the contributor's wallet address as the salt.
- **Account Registry** — The factory's append-only record of every account it deploys, queryable per contributor and via pagination.
- **Governance Delegation** — On creation, each account delegates its voting power back to the contributor, so locked `$BLOKC` retains its governance weight.
- **Single-Date Lock** — One uniform unlock timestamp shared by every account a factory creates, bound at deployment and immutable per account.

## Reward Distribution Flow

### Weekly cycle

1. **AI scores contributor work** off-chain (Discord, GitHub, X, on-chain activity) and computes reward amounts per contributor.
2. **AI proposes** on-chain via `BLOKCDistributor.proposeDistribution(epochId, contributors[], amounts[])`. The proposal is stored in contract storage and emitted as a `DistributionProposed` event.
3. **Cloudflare worker** detects the event, generates a pre-distribution report showing who gets what, and flags anomalies (unusually high amounts, new contributors). Report is sent to Slack/Discord/email.
4. **Signers review** the report. If OK, each signer calls `approveDistribution(epochId)`. All signers must approve — no partial quorum.
5. **Anyone executes** `executeDistribution(epochId)` once all signers have approved. Tokens are transferred to each contributor's deterministic account address.
6. **Tokens vest** in the contributor's vault until the unlock timestamp (May 1, 2027 00:00 UTC). Voting power is delegated back to the contributor immediately.

If the AI makes an error, it can cancel the proposal, re-compute amounts, and re-propose for the same epoch. All prior approvals are cleared on cancel.

### Access control

| Role | Can | Cannot |
|---|---|---|
| **Proposer** (AI wallet) | Propose distributions, cancel proposals | Approve, execute, manage signers |
| **Signers** (2+) | Approve proposed distributions | Propose, execute, manage other signers |
| **Owner** (DAO multisig) | Add/remove signers, rotate proposer, recover tokens | Propose, approve, execute distributions |
| **Anyone** | Execute fully-approved distributions | — |

No single role can unilaterally move tokens.

## Contracts

### BLOKCDistributor

`src/contracts/BLOKCDistributor.sol`

The core reward distribution contract.

| Function | Access | Description |
|---|---|---|
| `proposeDistribution(epochId, contributors[], amounts[])` | Proposer | Submit a distribution for an epoch |
| `approveDistribution(epochId)` | Signer | Approve a proposed distribution |
| `executeDistribution(epochId)` | Anyone | Execute a fully-approved distribution |
| `cancelDistribution(epochId)` | Proposer | Cancel and allow re-proposal |
| `addSigner(address)` | Owner | Add a signer |
| `removeSigner(address)` | Owner | Remove a signer (min 2 enforced) |
| `updateProposer(address)` | Owner | Rotate AI wallet |
| `updateOwner(address)` | Owner | Transfer ownership |
| `recoverTokens(token, to, amount)` | Owner | Sweep any ERC20 |

### BLOKCContributorAccount

`src/contracts/BLOKCContributorAccount.sol`

Per-contributor time-locked vault (EIP-1167 clone).

| Function | Access | Description |
|---|---|---|
| `withdraw(to, amount)` | Contributor, after unlock | Partial withdrawal |
| `withdrawTokensAll()` | Contributor, after unlock | Sweep full balance |
| `recoverERC20(token, to, amount)` | Contributor, any time | Recover non-BLOKC tokens |
| `balanceOf()` | Public | Current BLOKC balance |
| `isUnlocked()` | Public | Whether unlock has occurred |
| `timeUntilUnlock()` | Public | Seconds until unlock |

### BLOKCContributorFactory

`src/contracts/factory/BLOKCContributorFactory.sol`

Deterministic clone factory with append-only registry.

| Function | Description |
|---|---|
| `createContributorAccount()` | Deploy caller's account (self-deploy only, idempotent) |
| `predictContributorAccount(contributor)` | Compute deterministic address |
| `getAccounts(offset, limit)` | Paginated registry read |

## Key Patterns

**All-signers-must-approve:**
Every distribution requires approval from every designated signer. There is no configurable threshold — unanimity is enforced at the bytecode level. Minimum 2 signers enforced at construction and on removal.

**Send-to-predicted-address:**
The distributor sends BLOKC to `factory.predictContributorAccount(contributor)` — the deterministic CREATE2 address. If the account hasn't been deployed yet, tokens sit at the bare address and are captured when the clone is deployed. No factory changes needed.

**Pre-fund capable:**
Contributor accounts can receive BLOKC before deployment. The team or distributor sends tokens to the predicted address; when the contributor deploys their account, the balance is inherited automatically.

**Minimal-Proxy Clones (EIP-1167):**
Each contributor account is a lightweight clone that delegates its logic to a single shared implementation, so deploying a new account costs minimal gas while every account behaves identically. The implementation itself is locked at construction (`_disableInitializers`) and can never be initialized directly.

**Deterministic Addresses (CREATE2):**
Accounts are deployed with CREATE2 using the contributor's wallet address as the salt (`salt = bytes32(uint256(uint160(contributor)))`), so each wallet maps to exactly one knowable account address. The address can be computed — and pre-funded — before the account is deployed.

**Single-Date Time Lock:**
Every account from a factory shares one unlock timestamp, bound at deployment. Before it, `$BLOKC` is locked at the bytecode level; from the unlock second onward the contributor may withdraw any amount to any address, or sweep the full balance.

**Governance Delegation:**
On initialization an account delegates its voting power to the contributor, so locked `$BLOKC` continues to count toward governance throughout the lock period.

**Idempotent Factory Registry:**
The factory deploys at most one account per contributor; a repeat create call returns the existing account without redeploying. The registry tracks every account and is read via pagination (`getAccounts(offset, limit)`) to stay safe as it grows.

## Test Suite

156 tests across 12 suites: unit, integration, fuzz, invariant, and reentrancy.

```bash
forge test                    # All 156 tests
forge test -vvv               # Verbose output
forge test --match-path test/unit/BLOKCDistributor.t.sol  # Distributor only
```

CI runs `forge fmt --check`, `forge build --sizes`, and `forge test -vvv` with the `ci` profile (higher fuzz/invariant runs).

## Prerequisites

- Foundry installed (forge, cast, anvil)
- git (with submodule support)

### Clone & Setup

```bash
git clone --recursive https://github.com/BLOKCapital/blokc-v1-rewards
cd blokc-v1-rewards

# If you forgot --recursive
git submodule update --init --recursive
```

### Build

```bash
forge build
# or to see contract sizes
forge build --sizes
```

### Format

```bash
forge fmt
```

## Deployment

Deployment is handled via `script/Deploy.s.sol`. The script deploys the account implementation, factory, and BLOKCDistributor, verifies the implementation is locked, and logs all addresses and constructor args.

Deploy on Anvil:

```bash
anvil
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL_ANVIL \
  --private-key $PRIVATE_KEY_ANVIL \
  --broadcast
```

Deploy on a live network:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $API_KEY_ETHERSCAN
```

## Environment Variables

```bash
BLOKC_TOKEN=0x...              # Canonical BLOKC ERC20Votes token address
PRIVATE_KEY=0x...              # Deployer private key
RPC_URL=https://...            # RPC URL for target chain
API_KEY_ETHERSCAN=...          # Etherscan API key for contract verification
AI_PROPOSER=0x...              # AI agent's EOA wallet
DISTRIBUTOR_OWNER=0x...        # DAO multisig address
DISTRIBUTOR_SIGNER_1=0x...     # First designated signer
DISTRIBUTOR_SIGNER_2=0x...     # Second designated signer
FIRST_CONTRIBUTOR=0x...        # (Optional) smoke test address
```

Example `.env` (do not commit):

```bash
BLOKC_TOKEN=0x...
PRIVATE_KEY=0x...
API_KEY_ETHERSCAN=...
RPC_URL=https://...
AI_PROPOSER=0x...
DISTRIBUTOR_OWNER=0x...
DISTRIBUTOR_SIGNER_1=0x...
DISTRIBUTOR_SIGNER_2=0x...
```

## Development Workflow

- Write / modify contracts under `src/`.
- Add or update Forge tests in `test/`.
- Use `forge fmt` before committing.
- Run `forge test` (or `forge test -vvv`) locally before opening a PR.
- Use the deployment script in `script/` to exercise flows against testnets or a local Anvil node.

## Security

This repository constitutes contributor rewards logic for Blok Capital and should be treated as security-critical infrastructure.

- Slither v0.11.5: 22 INFO findings, 0 HIGH, 0 MEDIUM, 0 LOW
- Trail of Bits Code Maturity: Satisfactory (3.2/4.0)
- All contracts use Solidity 0.8.33 with built-in overflow protection
- CEI (Checks-Effects-Interactions) pattern on all state-mutating functions
- SafeERC20 for all token transfers
- No assembly, no delegatecall from project contracts
- Reentrancy protection verified by adversarial tests

If you believe you have found a vulnerability or deviation from the intended behavior, please report it responsibly to the Blok Capital team.

## Contributing

Contributions are welcome. For external contributors:

- Fork the repository and create a feature branch.
- Make your changes, ensuring contracts are formatted (`forge fmt`) and tests are updated/added.
- Run the full test suite with `forge test`.
- Open a pull request with a clear description of the change, its motivation, and any relevant deployment or migration considerations.

Security-sensitive changes (especially around the distributor, factory, account initialization, lock logic and withdrawals) should be accompanied by thorough tests and clear reasoning.

## Questions & Contact

Join our Discord: [https://discord.com/invite/blokc](https://discord.com/invite/blokc)
