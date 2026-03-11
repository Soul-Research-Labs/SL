# Changelog

All notable changes to the **Soul Privacy Stack** — a multi-chain ZK privacy middleware derived from ZAseon and Lumora — will be documented in this file.

## [0.8.0] - 2026-03-XX — Testing, Documentation & Infrastructure Hardening

### Testing

- **Noir circuit tests** — Added 15 tests across 3 circuits:
  - `nullifier_check`: 4 tests (valid inclusion, wrong nullifier, wrong path, right-child path)
  - `transfer`: 4 tests + `build_root_for_leaf()` helper (valid transfer, value mismatch, wrong nullifier, wrong commitment)
  - `withdraw`: 7 tests + helper (full withdrawal, partial withdrawal, value mismatch, zero value, zero recipient, wrong nullifier, zero secret)
- **Python SDK tests** — 23 new tests added:
  - `test_client.py`: 15 tests for `SoulPrivacyClient` (chain_id, pool_address, get_latest_root, is_known_root, is_nullifier_spent, get_pool_balance, commitment_exists, build_deposit_tx, build_transfer_tx, build_withdraw_tx, ABI checks)
  - `test_prover.py`: 8 async tests for `ProofClient` (health, prove_transfer, prove_withdraw, payload validation, HTTP error handling)
- **CosmWasm tests** — Expanded from 9 to 22 `cw-multi-test` integration tests
- **NEAR tests** — 30 new unit tests for privacy pool contract
- **ink! tests** — Expanded from 8 to 22 unit tests
- **Solidity fork tests** — Added 5 chain-specific fork test files (Fuji, Moonbase, Shibuya, Evmos, Aurora)
- **Solidity integration tests** — Added deposit lifecycle and multi-chain relay integration tests
- **Solidity fuzz tests** — Added deep fuzz tests for deposit amounts, merkle root consistency, nullifier uniqueness, and cross-chain value conservation

### Formal Verification

- **Certora BridgeAdapters.spec** — Replaced placeholder with 9 formal verification properties: processedMessageMonotonicity, governanceNonZero invariant, onlyGovernanceCanRegisterChain, governanceTransferCorrectness, sendMessageImpliesChainSupported, receiveDoesNotAffectBalance, chainRegistrationPersistence, receiveMessageNeverReverts, sendAndReceiveOrthogonal

### SDK

- **Python SDK expanded** — Added `ProofClient`, `ChainType`, `GeneratedProof`, `ProofRequest` to `__init__.py` exports; added `pytest-httpx` dev dependency; added `asyncio_mode = "auto"` config
- **Python SDK README** — New documentation with quick start, module reference, proof generation example, and testing instructions
- **TypeScript SDK TypeDoc** — Configured API documentation generation
- **SDK address loader** — Utility for loading deployment addresses

### Documentation

- **DEPLOYMENT_CHECKLIST.md** — Comprehensive 9-section deployment guide: prerequisites, environment setup, deployment order, per-chain EVM steps, non-EVM deployments, post-deployment verification, cross-chain configuration, governance handoff, operational readiness, rollback procedures
- **ARCHITECTURE.md** — System architecture overview and component descriptions
- **GETTING_STARTED.md** — Developer onboarding guide
- **GOVERNANCE_PARAMETERS.md** — Governance configuration reference
- **THREAT_MODEL.md** — Security threat analysis and mitigations
- **MEV_PROTECTION.md** — MEV protection design document
- **Operational runbook** — ops/RUNBOOK.md with startup, health checks, emergency procedures
- **ADR/RFC process** — Added to CONTRIBUTING.md
- **SECURITY.md** — Updated with current vulnerability reporting process

### Infrastructure

- **Docker env configuration** — Added `env_file` to Lumora service; made all ports configurable via env vars; added healthchecks for relayer and lumora; made Prometheus retention and Grafana root URL configurable; added Docker/infra env vars to `.env.example`
- **Makefile deploy path fix** — Corrected all 7 deploy targets from `script/` to `scripts/deploy/`
- **Makefile new targets** — `test-noir`, `test-python`, `lint-python`, `subgraph-configure`, `test-sol-fuzz-deep`, `test-sol-fork`, `test-sol-integration`
- **Substrate pallet weights** — Enhanced `weights.rs` with detailed operation-level breakdowns and methodology documentation
- **Monitoring alerts** — Prometheus alert rules for epoch, relayer, and system health
- **Grafana Lumora dashboard** — Added coprocessor monitoring dashboard
- **Python SDK CI** — GitHub Actions workflow for Python SDK linting and testing
- **sdks/typescript/ cleanup** — Deprecated namespace; points users to primary `sdk/` directory

### Relayer

- **Config improvements** — Enhanced `config.example.toml` with detailed documentation and security notes

## [0.7.0] - 2026-07-XX — Security Hardening & Access Control Audit

### Security Fixes (P0 — Critical)

- **CosmWasm hash function** — Replaced completely broken XOR byte-folding mock with proper `sha2::Sha256` cryptographic hash; added `hex` and `sha2` crate dependencies
- **NEAR access control** — Added governance-only guard to `finalize_epoch()`, governance-or-authorized-relayer guard to `sync_epoch_root()` with null root rejection; added `authorized_relayer` field and `set_authorized_relayer()` governance function
- **CosmWasm access control** — Added governance-only guard to `finalize_epoch()`, governance-or-authorized-relayer guard to `sync_epoch_root()` with empty root validation; added `SetAuthorizedRelayer` execute message and handler
- **Substrate withdraw accounting** — Replaced broken `T::Currency::unreserve(&recipient)` (which tried to unreserve non-existent reserved balance) with proper `PalletId`-based treasury account: deposits transfer to pool account, withdrawals transfer from pool account to recipient
- **Substrate access control** — `finalize_epoch()` and `sync_epoch_root()` now require `ensure_root` (sudo/governance) origin instead of any signed origin; `sync_epoch_root()` rejects zero nullifier roots
- **NEAR verify strengthening** — Increased minimum proof length from 64 to 256 bytes, added non-zero root and output commitment validation
- **PrivacyPool receive()** — Changed from empty `receive()` (silently accepted untracked ETH) to `revert InvalidDeposit()` — all deposits must go through `deposit()`

### Security Fixes (P1 — High)

- **SDK ABI mismatch** — Added missing `amount` parameter to deposit ABI and `_domainChainId`/`_domainAppId` parameters to transfer ABI, matching actual Solidity contract signatures
- **Halo2SnarkVerifier VK immutability** — Added `VKAlreadyInitialized` error and guards to `initTransferVK()`, `initWithdrawVK()`, and `initAggregationVK()` preventing re-initialization of verification keys after initial setup
- **Subgraph config** — Added `address` fields (placeholder) to all data sources and changed `startBlock` from 0 to 1 with deployment instructions

### Security Fixes (P2 — Medium)

- **CosmWasm hardcoded denom** — Replaced hardcoded "uatom" deposit/withdraw denomination with configurable `accepted_denom` field in Config, set during contract instantiation
- **Router self-loops** — Removed IBC self-loop (`evmos-testnet` → `evmos-testnet`) and Rainbow self-loop (`aurora-testnet` → `aurora-testnet`) from bridge topology
- **Router key mismatch** — Changed all bridge topology keys from hyphens (`avalanche-fuji`) to underscores (`avalanche_fuji`) matching the `ALL_CHAINS` registry
- **Aggregator weak randomness** — Replaced `SystemTime::subsec_nanos()`-based jitter (predictable, identical for consecutive calls) with `rand::thread_rng().gen_range()` using the `rand` crate
- **Docker Grafana password** — Changed default password from `changeme` to mandatory `${GRAFANA_PASSWORD:?}` requiring explicit env var

### Testing

- **RelayerFeeVault.t.sol** — 18 Foundry tests: relayer registration (register, insufficient stake, already-registered, deregister, deregister-with-pending), fee deposits (deposit, zero, receive), relay credit (credit, duplicate hash, unregistered, insufficient vault, governance-only), fee claims (claim, nothing-to-claim), governance (setFeePerRelay, exceeds-max, slash, full-slash-deregisters, transfer-governance, zero-address), view functions
- **StealthAnnouncer.t.sol** — 12 Foundry tests: meta-address registration (register, invalid parities, update, unregistered-revert), announcement publishing (single, multiple), range queries (range, beyond-end, empty)

### Infrastructure

- **Substrate `PalletId`** — New `Config` associated type for treasury account derivation; added to test mock as `prv/pool`

## [0.6.0] - 2026-06-XX — Hardening, Crypto Fixes & Test Coverage

### Bug Fixes

- **VerifyDeployment.s.sol** — Fixed `view` modifier on `run()` and all internal functions that prevented counter state mutations; fixed `IEpochVerify.pool()` → `authorizedPools(address)` to match actual EpochManager interface
- **ink! privacy-pool withdraw** — Fixed single-nullifier withdraw to use `[[u8; 32]; 2]` (2 nullifiers + 2 output commitments), aligning with Solidity/CosmWasm/NEAR protocol
- **PrivacyPool.t.sol** — Fixed EpochManager constructor call (was missing `DOMAIN_CHAIN_ID` second parameter)
- **Submitter ABI selectors** — Replaced hardcoded placeholder selectors with `ethers::utils::keccak256()`-computed values for `transfer()` and `withdraw()`

### Security Improvements

- **lumora proof.rs** — Replaced `DefaultHasher`-based non-cryptographic hash with `sha3::Keccak256` for all off-chain nullifier/commitment computations; replaced zero-filled proof envelopes with random-padded envelopes for metadata resistance (`padded_proof_envelope()`)
- **ComplianceOracle viewing-key verifier** — Added `viewingKeyVerifier` address + `setViewingKeyVerifier()` governance function; proper ZK proof verification via `staticcall` to verifier contract (proof = `[32-byte auditorPubKeyHash][zkProof]`); fallback to accept-non-empty only when no verifier is set (testnet mode)

### Circuit Completion

- **Halo2 TransferCircuit** — Added full 32-level Merkle path verification for both inputs (with conditional swap via path bits), V2 domain-separated nullifier derivation (`Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`), output note 1 commitment computation, instance column exposure for `[merkle_root, nullifier_0, nullifier_1, out_commitment_0, out_commitment_1]`
- **Halo2 WithdrawCircuit** — Added Merkle path verification, V2 nullifier derivation, change note commitment, instance column exposure for `[merkle_root, nullifier, withdraw_value, change_commitment]`

### New Modules

- **Relayer Dispatcher** (`relayer/src/dispatcher.rs`) — Full relay command executor with `ethers-rs` transaction submission; ABI encoding for `receiveRemoteRoot()`, `sendMessage()`, `submitEpochRoot()` with keccak256-computed function selectors

### Testing

- **EpochManager.t.sol** — 20 Foundry tests: constructor initialization, nullifier registration (authorized/unauthorized/multiple), epoch lifecycle (startNewEpoch auto-finalize, before-duration revert, direct finalize, double-finalize revert, empty/single/multi root), cross-chain sync (receiveRemoteEpochRoot, unauthorized/zero-root reverts), global nullifier check, governance (authorize/revoke pool/bridge, setGovernance, unauthorized revert)
- **UniversalNullifierRegistry.t.sol** — 20 Foundry tests: chain registration (register/duplicate/unauthorized/deactivate/inactive/updateAdapter), epoch root submission (submit/unauthorized/duplicate/sequential/inactive/governance-submit), global snapshot (empty/single/multi-chain), nullifier reporting (single-element proof, duplicate/invalid/unregistered reverts), view helpers
- **Libraries.t.sol** — Unit tests for PoseidonHasher (determinism, non-commutativity, field-boundedness, modular reduction, hashSingle), DomainNullifier (V1/V2 computation, domain/app separation, verifyV2, V1≠V2 divergence), MerkleTree (init root, insert, sequential indices, isKnownRoot history, determinism), TransientStorage (reentrancy guard, uint/address/bytes32/bool store/load)

### Build & CI

- **rust.yml** — Added `ink-privacy-pool` and `soul-relayer` CI jobs (fmt, clippy, test, wasm build); added `ink/**` and `relayer/**` to trigger paths
- **BridgeAdapters.conf** — New Certora config for bridge adapter formal verification
- **Makefile** — `verify-bridges`, `test-sol-epochmanager`, `test-sol-registry`, `test-sol-libraries` targets; `verify-all` now covers 6 specs
- **lumora-coprocessor Cargo.toml** — Added `sha3` and `rand` dependencies

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
