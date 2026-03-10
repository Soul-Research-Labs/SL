# Contributing to Soul Privacy Stack

Thank you for your interest in contributing! This guide covers the development workflow for all components of the multi-chain ZK privacy stack.

## Development Setup

### Prerequisites

| Tool                                                        | Version | Component                                         |
| ----------------------------------------------------------- | ------- | ------------------------------------------------- |
| [Foundry](https://book.getfoundry.sh/)                      | latest  | Solidity contracts                                |
| [Rust](https://rustup.rs/)                                  | ≥ 1.75  | Substrate pallet, CosmWasm, Near, Relayer, Lumora |
| [Node.js](https://nodejs.org/)                              | ≥ 18    | TypeScript SDK                                    |
| [Nargo](https://noir-lang.org/)                             | ≥ 0.30  | Noir ZK circuits                                  |
| [cargo-contract](https://github.com/use-ink/cargo-contract) | ≥ 4.0   | ink! contract                                     |
| [Docker](https://www.docker.com/)                           | latest  | Relayer + monitoring stack                        |

### Quick Start

```bash
# Clone
git clone <repo-url> && cd soul-privacy-stack

# Solidity
forge build && forge test -vvv

# Rust workspace
cargo build --workspace
cargo test --workspace

# TypeScript SDK
cd sdk && npm install && npm test

# Noir circuits
cd noir/circuits/deposit && nargo test
cd ../transfer && nargo test

# Docker stack
cd docker && docker compose up -d
```

## Project Structure

```
contracts/          Solidity (EVM) — core contracts, bridges, libraries, verifiers
pallets/            Substrate FRAME pallet
ink/                ink! smart contract (Polkadot Wasm)
cosmwasm/           CosmWasm contract (Cosmos)
near/               Near Protocol contract
lumora-coprocessor/ Off-chain Halo2 proof generation
noir/circuits/      Noir ZK circuits
relayer/            Cross-chain relayer daemon (Rust)
sdk/                TypeScript SDK
docker/             Docker deployment
scripts/            Deploy scripts
test/               Foundry test suite
certora/            Formal verification specs
```

## Contribution Workflow

1. **Fork** and create a feature branch from `main`
2. **Write code** following the style guide below
3. **Add tests** — all changes must include tests
4. **Run CI checks locally** before pushing
5. **Open a PR** with a clear description

### Branch Naming

- `feat/short-description` — New features
- `fix/short-description` — Bug fixes
- `refactor/short-description` — Refactoring
- `docs/short-description` — Documentation

## Style Guide

### Solidity

- Solidity 0.8.24, optimizer enabled (200 runs)
- NatSpec documentation on all public functions
- Custom errors preferred over `require` strings (gas efficiency)
- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)

### Rust

- `cargo fmt` + `cargo clippy` must pass
- Use `#[must_use]` on functions returning `Result`
- Prefer `thiserror` for error types
- Follow [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)

### TypeScript

- Strict TypeScript (`strict: true`)
- Use `viem` for all EVM interactions (not `ethers`)
- Export types alongside implementations
- Prefer `interface` over `type` for public APIs

### Noir

- Include test cases in each circuit file
- Document public inputs/outputs clearly
- Use helper functions for repeated Poseidon patterns

## Testing Requirements

| Component  | Framework            | Required Coverage              |
| ---------- | -------------------- | ------------------------------ |
| Solidity   | Foundry (forge test) | All public functions           |
| Rust       | `cargo test`         | All dispatchables + edge cases |
| TypeScript | Jest                 | All exports + error paths      |
| Noir       | `nargo test`         | Circuit constraints verified   |
| Certora    | Certora Prover       | Critical invariants            |

### Running Tests

```bash
# All Solidity tests
forge test -vvv

# Specific Solidity test
forge test --match-test test_deposit -vvv

# Gas benchmarks
forge test --match-contract GasBenchmark --gas-report

# Rust workspace tests
cargo test --workspace

# Substrate pallet tests
cargo test -p pallet-privacy-pool

# CosmWasm integration tests
cargo test -p cosmwasm-privacy-pool

# SDK tests
cd sdk && npm test

# Noir circuit tests
cd noir/circuits/deposit && nargo test
```

## Security

- Read [SECURITY.md](SECURITY.md) before contributing
- Never commit private keys, mnemonics, or API keys
- All cryptographic operations must use audited libraries
- ZK circuits require soundness review before merge
- Bridge adapters require extra review (cross-chain attack surface)

## Deployment

Deploy scripts live in `scripts/deploy/`. Each chain has its own script:

| Chain     | Script                  | Tool           |
| --------- | ----------------------- | -------------- |
| Avalanche | `DeployAvalanche.s.sol` | `forge script` |
| Moonbeam  | `DeployMoonbeam.s.sol`  | `forge script` |
| Astar     | `DeployAstar.s.sol`     | `forge script` |
| Evmos     | `DeployEvmos.s.sol`     | `forge script` |
| Aurora    | `DeployAurora.s.sol`    | `forge script` |
| Near      | `deploy-near.sh`        | `near-cli-rs`  |

## License

MIT — see [LICENSE](LICENSE) for details.
