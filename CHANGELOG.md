# Changelog

All notable changes to the **Soul Privacy Stack** — a multi-chain ZK privacy middleware derived from ZAseon and Lumora — will be documented in this file.

## [0.5.0] - 2026-05-XX — Compliance, Verification & Documentation

### Core Integration

- **ComplianceOracle integrated into PrivacyPool** — `transfer()` and `withdraw()` now call `complianceOracle.checkCompliance()` when oracle is set; `withdraw()` additionally checks `isBlocked(recipient)`; configurable via `setComplianceOracle()` governance function; `address(0)` disables compliance (backward compatible)

### Testing

- **MultiSigGovernance.t.sol** — 28 Foundry tests: constructor validation (empty owners, invalid threshold, duplicates, zero address), submit/confirm lifecycle (auto-confirm, non-owner rejection), revoke confirmation, execute (success, insufficient confirmations, double execution, reverting target, ETH transfer), `isExecutable()` transitions, self-governance via proposals (addOwner, removeOwner with threshold auto-adjustment, changeThreshold, last-owner removal prevention), 1-of-1 edge case, ETH receive
- **FeeEstimator SDK tests** (`sdk/src/__tests__/fees.test.ts`) — Jest tests with mocked viem: fee breakdown correctness, gas/protocol/tip overrides, on-chain vault fee lookup, vault fallback, small withdrawal not-economical check, `isWithdrawalEconomical()`, `minimumEconomicalWithdrawal()` boundary verification

### SDK Enhancements

- **SubgraphClient** (`sdk/src/subgraph.ts`) — GraphQL query client for The Graph: deposits, transfers, withdrawals, epochs, pool metrics, timelock transactions; pagination support, nullifier-based search, convenience `isNullifierSpent()` method
- **TypeDoc configuration** (`sdk/typedoc.json`) — API doc generation via `npm run docs`; markdown plugin for repo-friendly output

### Formal Verification

- **Certora spec for MultiSigGovernance** — 15 rules: threshold bounds invariant, owner count invariant, only-owner submit/confirm, auto-confirm on submit, double-confirm rejection, confirm/revoke count tracking, execution threshold requirement, no double execution, monotonic proposal count, self-only governance functions (addOwner/removeOwner/changeThreshold), addOwner count verification

### Circuits

- **Noir stealth address circuit** (`noir/circuits/stealth/`) — ZK proof of correct DKSAP-style stealth address derivation: ephemeral keypair verification, shared secret computation, stealth address derivation, view tag extraction; 4 Noir tests (valid derivation, wrong spend key, wrong ephemeral key, zero key rejection)

### Build & Config

- Makefile: `test-sol-multisig`, `docs-sdk`, `verify-multisig`, `verify-timelock`, `verify-compliance` targets; `verify-all` now covers 5 specs
- SDK: TypeDoc + markdown plugin dev dependencies, `docs` script in package.json

### Breaking Changes

- `PrivacyPool` constructor now requires 6th `_complianceOracle` parameter — all deploy scripts and tests updated with `address(0)` (disabled by default)

## [0.4.0] - 2026-04-XX — Integration, Governance & Monitoring

### Core Integration

- **EmergencyPause integrated into PrivacyPool** — `deposit`, `transfer`, and `withdraw` now gated by `whenNotPaused`; constructor accepts guardian address; `_pauseGovernance()` wired to governance address
- **MultiSigGovernance Contract** — M-of-N multi-signature wallet: submit/confirm/revoke/execute proposals, self-governance (add/remove owners, change threshold), designed as timelock admin

### Infrastructure

- **Subgraph (The Graph)** — Full schema + AssemblyScript mappings for PrivacyPool events (Deposit, Transfer, Withdrawal, Pause/Unpause), EpochManager (EpochFinalized, RemoteRootReceived), GovernanceTimelock (Queued/Executed/Cancelled); aggregated PoolMetrics entity
- **Grafana Dashboard** — Provisioned relayer dashboard with 12 panels: epoch/relay counters, rate graphs, chain health gauge, uptime, failure pie chart, registry submission rate; auto-provisioned datasource
- **Docker Compose updated** — Grafana volumes for provisioning and dashboards

### SDK Enhancements

- **FeeEstimator** (`sdk/src/fees.ts`) — Withdrawal fee estimation: gas cost + relayer tip + protocol fee breakdown, economical check, minimum withdrawal calculator, on-chain RelayerFeeVault fee lookup with fallback

### Libraries

- **TransientStorage** (`contracts/libraries/TransientStorage.sol`) — EIP-1153 transient storage library: `TransientReentrancyGuard` (~95% gas savings), general-purpose `tstore`/`tload` helpers for uint256/address/bytes32/bool, derived slot computation

### Scripts

- **VerifyDeployment** (`scripts/VerifyDeployment.s.sol`) — Post-deploy verification: PrivacyPool checks (verifier, epochManager, domainIds, pause state, merkle tree), EpochManager, GovernanceTimelock, ComplianceOracle, cross-link validation

### Testing

- **CrossChainRelay.t.sol** — 10 integration tests with MockBridgeAdapter: single-chain finalization, A→B relay, bidirectional relay, multi-epoch batch relay, unauthorized bridge rejection, different epoch roots, empty epoch, relay idempotency, multi-source batch, full lifecycle simulation

### Breaking Changes

- `PrivacyPool` constructor now requires a 5th `_guardian` parameter — all deploy scripts and tests updated

## [0.3.0] - 2026-03-XX — Governance, Safety & Observability

### Governance & Safety

- **GovernanceTimelock Contract** — Time-delayed execution for all privileged operations: queue/execute/cancel lifecycle, configurable delay (1hr–30d), 14-day grace period, two-step admin transfer
- **EmergencyPause Module** — Abstract circuit-breaker with guardian (immediate pause) and governance (unpause) separation, MAX_PAUSE_DURATION safety valve (7 days), composable `whenNotPaused` modifier

### SDK Enhancements

- **ProofClient** (`sdk/src/prover.ts`) — HTTP client for the Lumora coprocessor: `proveDeposit`, `proveTransfer`, `proveWithdraw`, health checks, BigInt serialization, configurable timeout
- **Stealth Address Tests** (`sdk/src/__tests__/stealth.test.ts`) — Comprehensive Jest tests for ephemeral keypair generation, shared secret computation, stealth address derivation, view tag computation, announcement creation, scanning

### Infrastructure

- **Relayer Health Endpoint** (`relayer/src/health.rs`) — Combined `/health` (JSON), `/ready` (200/503), and `/metrics` (Prometheus) HTTP server; chain connectivity tracking, uptime, last relay timestamp
- **Relayer lib.rs updated** — Integrated HealthState with combined health+metrics server

### Testing

- **GovernancePauseStealth.t.sol** — Foundry tests for GovernanceTimelock (10 tests: queue/execute/cancel, delay enforcement, stale/cancelled tx, admin transfer, ETH transfer), EmergencyPause (10 tests: pause/unpause, guardian vs governance, MAX_PAUSE_DURATION safety valve, modifier behavior), Stealth full-flow integration (register → announce → scan → verify, multi-announcement pagination)

### Formal Verification

- **GovernanceTimelock.spec** — Certora spec: admin-only access, delay enforcement, queue/execute/cancel flag lifecycle, delay bounds invariant
- **ComplianceOracle.spec** — Certora spec: governance-only blocking, policy monotonicity, auditor management, governance transfer
- **RelayerFeeVault.spec** — Certora spec: relay uniqueness, stake requirements, fee conservation, slash correctness
- **3 Certora conf files** — GovernanceTimelock.conf, ComplianceOracle.conf, RelayerFeeVault.conf

### Documentation

- **README.md** — Added Governance & Safety section, SDK Proof Client docs, updated Certora table (6 specs), updated project structure

## [0.1.0] - 2024-07-XX — Initial Implementation

### Core Architecture

- **Solidity Core Contracts** — `PrivacyPool.sol`, `EpochManager.sol`, `UniversalNullifierRegistry.sol` implementing incremental Merkle tree (depth 32, 100-root history), domain-separated V2 nullifiers, epoch-based root management
- **PoseidonHasher Library** — BN254 Poseidon (T=3) for commitment and nullifier hashing
- **DomainNullifier Library** — V1 and V2 nullifier derivation: `Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`

### Bridge Adapters

- **Avalanche AWM Adapter** — Cross-subnet messaging via Warp Messaging precompile (0x0200…0005), BLS multi-sig verification
- **Teleporter Adapter** — Higher-level Avalanche bridging for simpler cross-subnet transfers
- **XCM Bridge Adapter** — Polkadot cross-consensus messaging for Moonbeam ↔ Astar relay
- **IBC Bridge Adapter** — Cosmos IBC packet relay for Evmos/Cosmos chain interop
- **Aurora Rainbow Adapter** — Near Protocol Rainbow Bridge for Aurora ↔ Near transfers

### ZK Proof Systems

- **Halo2SnarkVerifier** — Full Groth16 BN254 pairing-based verifier for on-chain Halo2→SNARK proof verification (~250K gas)
- **UltraHonkVerifier** — Noir UltraHonk verifier for fallback proof system
- **4 Noir Circuits** — Deposit (commitment correctness), Transfer (2-in 2-out with Merkle proofs), Withdraw (with optional change), Nullifier Check (cross-chain inclusion)
- **Halo2 Circuit Definitions** — `TransferCircuit` and `WithdrawCircuit` with `PoseidonChip` (full/partial rounds, x^5 S-box) and `MerkleConfig` for Lumora coprocessor

### Native Integrations

- **Substrate Pallet** (`pallets/privacy-pool`) — FRAME pallet with deposit, transfer, withdraw, `finalize_epoch`, `sync_epoch_root` dispatchables; XCM message handler for cross-parachain root synchronization
- **ink! Smart Contract** (`ink/privacy-pool`) — Native Substrate smart contract for non-EVM parachains (Astar Wasm VM), matching Solidity/CosmWasm feature set
- **CosmWasm Contract** (`cosmwasm/contracts/privacy-pool`) — Cosmos-native privacy pool with `cw-multi-test` integration tests
- **Near Contract** (`near/contracts/privacy-pool`) — Near Protocol native privacy pool

### Cross-Chain Infrastructure

- **Cross-Chain Relayer** — Rust async daemon with chain watchers (WebSocket + HTTP polling fallback), event aggregator (batching, timing jitter), relay command dispatch. Metadata resistance: configurable jitter, batch windows, dummy message padding
- **Prometheus Metrics** — `/metrics` HTTP endpoint exposing `relayer_epochs_received_total`, `relayer_relays_dispatched_total`, `relayer_relay_failures_total`, `relayer_registry_submissions_total`
- **Lumora Coprocessor** — Rust ZK proof generation service with chain-specific submitters

### SDK

- **TypeScript SDK** (`@soul-privacy/sdk`) — `SoulPrivacyClient` (per-chain) and `MultiChainPrivacyManager` (multi-chain orchestration) using viem
- **Cross-Chain Router** — BFS pathfinding across 11 bridge edges (5 protocols), global nullifier checking, pool status aggregation, shielded cross-chain transfers
- **10 Chain Configs** — Avalanche C-Chain, Fuji, Moonbeam, Moonbase Alpha, Astar, Shibuya, Evmos, Evmos Testnet, Aurora, Aurora Testnet

### Testing & Verification

- **Foundry Tests** — Unit tests for PrivacyPool, BridgeAdapters + NullifierRegistry, gas benchmarks (deposit, transfer, withdraw, cross-chain operations)
- **E2E Integration Script** — Full stack deployment and test (verifier → epochManager → pool → registry → deposits → epoch → snapshot)
- **Certora Specs** — Formal verification specs for PrivacyPool (nullifier uniqueness, root validity, balance conservation), NullifierRegistry (epoch ordering, snapshot integrity), BridgeAdapters (message authentication)
- **Substrate Pallet Tests** — 12 unit tests covering deposit, root changes, epoch management, remote root sync, balance tracking
- **CosmWasm Integration Tests** — 9 `cw-multi-test` tests covering instantiate, deposits, epoch management, governance

### Deployment

- **5 Deploy Scripts** — Avalanche, Moonbeam, Astar, Evmos, Aurora (Foundry `forge script`)
- **4 CI/CD Workflows** — Solidity (forge build/test), Rust (cargo check/test), SDK (npm test), Testnet deploy (on workflow_dispatch)
- **Docker** — Multi-stage Dockerfiles for relayer and Lumora coprocessor, `docker-compose.yml` with Prometheus + Grafana monitoring stack
- **Example Runtime** — Substrate runtime integrating the privacy-pool pallet with cumulus parachain support

### Documentation

- **README.md** — Architecture diagram, chain compatibility table, crypto primitives, project structure, quickstart, deployment guides, SDK usage, relayer configuration, security considerations

## [0.2.0] - 2024-08-XX — Enhancement Round: Privacy Primitives & Tooling

### Privacy Primitives

- **StealthAddress Library** — ECDH-based unlinkable recipient addresses with `deriveStealthAddress`, `computeViewTag`, `computeStealthCommitment` (secp256k1, Poseidon-based)
- **StealthAnnouncer Contract** — On-chain stealth announcement registry with meta-address registration, batched announcement scanning, view tag filtering
- **ComplianceOracle Contract** — IComplianceOracle implementation with address/commitment blocklists, authorized auditor management, policy versioning, governance-only controls, configurable EDD thresholds
- **RelayerFeeVault Contract** — Relayer incentivization with staking, fee deposits, per-relay credits, claimable balance, slashing mechanism, governance fee controls

### SDK Enhancements

- **NoteWallet** — Client-side shielded note management: add/mark-spent, greedy note selection, domain-separated V2 nullifier computation, import/export with BigInt serialization, stealth meta-address derivation
- **Stealth Address Module** (`sdk/src/stealth.ts`) — Client-side ECDH helpers: ephemeral keypair generation, shared secret computation, stealth address derivation, view tag computation, announcement creation, single/batch announcement scanning with view tag filtering
- **SDK Exports** — All stealth types and functions exported from package entry point

### Testing

- **Foundry Invariant/Fuzz Tests** (`InvariantPrivacyPool.t.sol`) — Handler-based invariant testing with ghost variables (totalDeposited, totalWithdrawn, commitmentCount, nullifierCount), 4 invariants (balance conservation, solvency, leaf monotonicity, non-negative balance), 6 fuzz test cases
- **New Contract Tests** (`NewContracts.t.sol`) — Comprehensive Foundry tests for StealthAnnouncer (registration, announcements, batch scanning, parity validation), ComplianceOracle (blocklists, compliance checks, auditor management, governance, policy versioning), RelayerFeeVault (registration/staking, fee deposits, relay credits, claims, slashing, deregistration, governance controls)
- **SDK Wallet Tests** (`wallet.test.ts`) — 20+ Jest tests for NoteWallet covering addNote, markSpent, getUnspentNotes, getBalance, selectNotesForSpend (greedy, insufficient), computeNullifier (domain separation), export/import roundtrip, getStealthMetaAddress

### Infrastructure

- **Relayer Binary** (`relayer/src/main.rs`) — CLI entry point with clap arg parsing, TOML config loading, tracing subscriber (text/json), structured logging
- **Lumora Coprocessor Binary** (`lumora-coprocessor/src/main.rs`) — CLI with `serve` (HTTP proof service), `prove` (single proof from JSON), `health` subcommands; configurable bind/port/workers
- **Makefile** — 30+ targets for build/test/lint/deploy/docker/verify across all components (Solidity, Rust, TypeScript, Noir)

### Security & Governance

- **SECURITY.md** — Responsible disclosure policy, security architecture overview, audit status
- **CONTRIBUTING.md** — Contribution guidelines, code standards, PR process

### Deployment

- **Near Deploy Script** (`deploy-near.sh`) — Automated build + deploy for NEAR testnet
- **CosmWasm Deploy Script** (`deploy-cosmwasm.sh`) — Automated build + deploy for Cosmos chains
- **Substrate Benchmarking** — `frame_benchmarking` v2 for all 5 pallet dispatchables

### Documentation

- **CHANGELOG.md** — This changelog tracking all notable changes
