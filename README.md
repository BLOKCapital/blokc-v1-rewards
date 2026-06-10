# Blokc V1 Rewards

Contributor rewards smart contracts for Blok Capital's v1 protocol.

This repository contains the time-lock layer of Blok Capital: per-contributor, deterministically deployed accounts that hold the `$BLOKC` a contributor accrues over time and release it after a single unlock date. It is intended to be the canonical on-chain implementation the DAO uses to distribute contributor rewards, with each contributor's balance isolated in its own account.

## Architecture

- **Contributor Accounts** – Per-contributor, time-locked vaults that hold `$BLOKC` and release the full balance after one unlock timestamp. Implemented as minimal-proxy clones (EIP-1167).
- **Contributor Factory** – Deterministically deploys Contributor Accounts via CREATE2 (one account per contributor), using the contributor's wallet address as the salt.
- **Account Registry** – The factory's append-only record of every account it deploys, queryable per contributor and via pagination.
- **Governance Delegation** – On creation, each account delegates its voting power back to the contributor, so locked `$BLOKC` retains its governance weight.
- **Single-Date Lock** – One uniform unlock timestamp shared by every account a factory creates, bound at deployment and immutable per account.

The architecture is designed for predictability, gas efficiency, and isolation, while keeping each contributor's rewards self-contained in their own account.


### Prerequisites

- Foundry installed (forge, cast, anvil)
- git (with submodule support)
- A modern version of bash/zsh

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

### Tests

Tests are written using Foundry's native Solidity test framework, spanning unit, fuzz, invariant, integration and reentrancy suites under `test/`.

```bash
# run all tests
forge test

# verbose output
forge test -vvv

# run a specific test file
forge test --match-path test/<TestFile>.sol
```

In CI, the `ci` profile is used (higher fuzzing and invariant runs).

## Deployment

Deployment is handled via Forge scripts in `script/`. The script deploys the account implementation and the factory, asserts the implementation cannot be initialized directly, then logs the addresses and constructor args for verification.

Deploy on Anvil:

```bash
# 1. Start a local node (for local testing)
anvil

# 2. Run deploy script against a network
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

To resume verification if contracts are deployed but not verified:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --resume \
  --verify \
  --etherscan-api-key $API_KEY_ETHERSCAN
```

## Environment Variables

Environment variables are consumed by the Forge scripts. At minimum you will need:

- `BLOKC_TOKEN` – Canonical `$BLOKC` (ERC20Votes) token address.
- `PRIVATE_KEY` – Deployer private key (hex, 32 bytes).
- `RPC_URL` – RPC URL of the chain you're deploying.
- `API_KEY_ETHERSCAN` – Etherscan API key for verifying contracts on block scanners.
- `FIRST_CONTRIBUTOR` – (Optional) address used for the post-deploy prediction smoke test.

Example `.env` (do not commit this file):

```bash
BLOKC_TOKEN=0x...
PRIVATE_KEY=0x...
API_KEY_ETHERSCAN=...
RPC_URL=https://...
```

## Key Concepts & Patterns

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


## Development Workflow

- Write / modify contracts under `src/`.
- Add or update Forge tests in `test/`.
- Use `forge fmt` before committing.
- Run `forge test` (or `forge test -vvv`) locally before opening a PR.
- Use the deployment script in `script/` to exercise flows against testnets or a local Anvil node.

## Security & Bug Bounty

This repository constitutes contributor rewards logic for Blok Capital and should be treated as security-critical infrastructure.

If you believe you have found a vulnerability or deviation from the intended behavior, please report it responsibly to the Blok Capital team.

Details about any bug bounty or formal disclosure program will be published by Blok Capital separately.

## Contributing

Contributions to `blokc-v1-rewards` are welcome. For external contributors:

- Fork the repository and create a feature branch.
- Make your changes, ensuring contracts are formatted (`forge fmt`) and tests are updated/added.
- Run the full test suite with `forge test`.
- Open a pull request with a clear description of the change, its motivation, and any relevant deployment or migration considerations.

Security-sensitive changes (especially around the factory, account initialization, lock logic and withdrawals) should be accompanied by thorough tests and clear reasoning.

## Questions & Contact

If you want to discuss the protocol, have doubts, or are considering contributing, you can join our Discord https://discord.com/invite/blokc
