# SL Privacy Stack — Multi-Chain ZK Privacy Infrastructure

> Cross-chain privacy middleware for Polkadot, Avalanche.  
> Inspired by [ZAseon](https://github.com/ZAseon) and [Lumora](https://github.com/lumora-labs) — unified into a single privacy stack.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Soul Privacy Stack                          │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│   │  TypeScript  │  │   Lumora     │  │  Cross-Chain         │   │
│   │  SDK         │  │   Coprocessor│  │  Relayer             │   │
│   │  (viem)      │  │   (Halo2)    │  │  (Rust/tokio)        │   │
│   └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘   │
│          │                 │                      │              │
│   ┌──────▼─────────────────▼──────────────────────▼───────────┐  │
│   │                   EVM Contracts Layer                     │  │
│   │  PrivacyPool · EpochManager · UniversalNullifierRegistry  │  │
│   │  PoseidonHasher · MerkleTree · DomainNullifier            │  │
│   │  Halo2SnarkVerifier · UltraHonkVerifier                   │  │
│   └────────┬──────────────┬──────────────┬───────────┬────────┘  │
│            │              │              │           │           │
│   ┌────────▼────┐ ┌──────▼─────┐ ┌──────▼────┐ ┌───▼────────┐    │
│   │ Avalanche   │ │ Polkadot   │ │ Cosmos    │ │ Near       │    │
│   │ AWM         │ │ XCM        │ │ IBC       │ │ Rainbow    │    │
│   │ Teleporter  │ │ Moonbeam   │ │ Evmos     │ │ Aurora     │    │
│   └─────────────┘ │ Astar      │ └───────────┘ └────────────┘    │
│                   └────────────┘                                 │
│                                                                  │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │              Native Substrate Pallet                     │   │
│   │  pallet-privacy-pool (FRAME) + XCM Handler               │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │  CosmWasm Privacy Pool  │  Near Privacy Pool Contract    │   │
│   └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Supported Chains

| Chain               | Type           | Bridge Protocol  | Status               |
| ------------------- | -------------- | ---------------- | -------------------- |
| Avalanche C-Chain   | EVM            | AWM / Teleporter | ✅ Core              |
| Avalanche Subnets   | EVM            | AWM              | ✅ Core              |
| Moonbeam            | EVM (Polkadot) | XCM Precompile   | ✅ Core              |
| Astar               | EVM (Polkadot) | XCM Precompile   | ✅ Core              |
| Evmos               | EVM (Cosmos)   | IBC Precompile   | ✅ Supported         |
| Aurora              | EVM (Near)     | Rainbow Bridge   | ✅ Supported         |
| Polkadot Parachains | Substrate      | XCM Native       | ✅ Native Pallet     |
| Cosmos Chains       | CosmWasm       | IBC              | ✅ CosmWasm Contract |
| Near Protocol       | Near VM        | Rainbow Bridge   | ✅ Near Contract     |

## Key Cryptographic Primitives

- **Poseidon Hash** (T=3, BN254 scalar field) — ZK-friendly commitments and Merkle hashing
- **Depth-32 Incremental Merkle Tree** — 100-root history ring buffer
- **Domain-Separated Nullifiers V2** — `Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`
- **Halo2 → Groth16 SNARK Wrapper** — IPA proofs wrapped for EVM verification (~250K gas)
- **UltraHonk Verifier** — Noir circuit proofs via HonkVerificationKey
- **Pedersen Commitments** — Note value hiding
- **Stealth Addresses** — ECDH-based unlinkable recipients with view tag scanning

## Project Structure

```
├── contracts/
│   ├── interfaces/          # IBridgeAdapter, IPrivacyPool, IProofVerifier, ...
│   ├── libraries/           # PoseidonHasher, MerkleTree, DomainNullifier, ProofEnvelope, StealthAddress
│   ├── core/                # PrivacyPool, EpochManager, NullifierRegistry, ComplianceOracle,
│   │                        # StealthAnnouncer, RelayerFeeVault, GovernanceTimelock, EmergencyPause,
│   │                        # MultiSigGovernance
│   ├── bridges/             # AvaxWarp, Teleporter, XCM, IBC, AuroraRainbow adapters
│   └── verifiers/           # Halo2SnarkVerifier, UltraHonkVerifier
├── scripts/deploy/          # Foundry deploy scripts per chain
├── test/                    # Foundry tests: PrivacyPool, EpochManager, NullifierRegistry, Libraries, MultiSig, CrossChain, RelayerFeeVault, StealthAnnouncer
├── certora/                 # Formal verification specs + configs (6 specs: Pool, Registry, MultiSig, Timelock, Compliance, Bridges)
├── noir/circuits/           # Noir ZK circuits (deposit, transfer, withdraw, nullifier_check, stealth)
├── sdk/                     # TypeScript SDK (client, router, wallet, stealth, prover, fees, subgraph, chain configs)
├── subgraph/                # The Graph subgraph (schema, mappings for PrivacyPool, EpochManager, Governance)
├── pallets/privacy-pool/    # Substrate FRAME pallet + XCM handler + benchmarking
├── ink/privacy-pool/        # ink! smart contract for native Substrate (Wasm VM)
├── lumora-coprocessor/      # Off-chain Halo2 proof generation + circuit definitions
├── cosmwasm/                # CosmWasm privacy pool contract
├── near/                    # Near privacy pool contract
├── relayer/                 # Cross-chain event relayer (Rust) with Prometheus metrics + dispatcher
├── runtime/                 # Example Substrate runtime integration
├── docker/                  # Dockerfiles + docker-compose (relayer, lumora, monitoring, Grafana dashboards)
└── .github/workflows/       # CI/CD (Solidity, Rust, SDK, deploy)
```

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (Solidity)
- [Rust](https://rustup.rs/) ≥ 1.75 (Rust crates)
- [Node.js](https://nodejs.org/) ≥ 18 (TypeScript SDK)

### Build Solidity Contracts

```bash
forge build
```

### Run Solidity Tests

```bash
forge test -vvv
```

### Build Rust Crates

```bash
cargo build --workspace
```

### Build TypeScript SDK

```bash
cd sdk && npm install && npm run build
```

## Deployment

### Avalanche C-Chain (Fuji Testnet)

```bash
cp .env.example .env
# Set PRIVATE_KEY, FUJI_RPC_URL, ETHERSCAN_API_KEY

forge script scripts/deploy/DeployAvalanche.s.sol \
  --rpc-url $FUJI_RPC_URL \
  --broadcast \
  --verify
```

### Moonbeam (Moonbase Alpha)

```bash
forge script scripts/deploy/DeployMoonbeam.s.sol \
  --rpc-url $MOONBASE_RPC_URL \
  --broadcast
```

### Astar (Shibuya Testnet)

```bash
forge script scripts/deploy/DeployAstar.s.sol \
  --rpc-url $SHIBUYA_RPC_URL \
  --broadcast
```

### Evmos (Testnet)

```bash
forge script scripts/deploy/DeployEvmos.s.sol \
  --rpc-url $EVMOS_TESTNET_RPC_URL \
  --broadcast
```

### Aurora (Testnet)

```bash
forge script scripts/deploy/DeployAurora.s.sol \
  --rpc-url $AURORA_TESTNET_RPC_URL \
  --broadcast
```

## SDK Usage

```typescript
import { SoulPrivacyClient, MultiChainPrivacyManager } from "soul-privacy-sdk";

// Single-chain client
const client = new SoulPrivacyClient({
  chainId: 43113, // Fuji
  rpcUrl: "https://api.avax-test.network/ext/bc/C/rpc",
  poolAddress: "0x...",
  epochManagerAddress: "0x...",
});

// Deposit
const tx = await client.deposit(commitment, { value: parseEther("1") });

// Multi-chain manager
const manager = new MultiChainPrivacyManager([
  { chainId: 43113, config: fujiConfig },
  { chainId: 1287, config: moonbaseConfig },
]);

// Cross-chain nullifier check
const isSpent = await manager.isNullifierSpentAnywhere(nullifier);
```

## Cross-Chain Relayer

The relayer watches `EpochFinalized` events on each chain and propagates epoch roots to the Universal Nullifier Registry and all peer chains.

```bash
# Configure relayer
cp relayer/config.example.toml relayer/config.toml

# Run
cargo run -p soul-relayer
```

Features:

- **WebSocket subscriptions** with HTTP polling fallback
- **Metadata resistance**: configurable timing jitter + event batching
- **Multi-chain fan-out**: Each epoch root is relayed to registry + all peer chains
- **Confirmation tracking**: Waits for N block confirmations before relaying

## Universal Nullifier Registry

A hub contract deployed on a central chain (e.g., Avalanche C-Chain) that:

1. **Registers chains** — governance adds each chain with its bridge adapter
2. **Receives epoch roots** — bridge adapters submit finalized epoch roots sequentially
3. **Creates global snapshots** — Poseidon-aggregates all chains' latest roots
4. **Verifies cross-chain nullifier proofs** — any chain can prove a nullifier is spent elsewhere

## Formal Verification

Certora specs cover critical invariants:

| Spec                      | Properties                                                                                                                    |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `PrivacyPool.spec`        | Nullifier irreversibility, no double-spend, commitment uniqueness, leaf monotonicity, root history integrity                  |
| `NullifierRegistry.spec`  | Governance-only registration, sequential epochs, no duplicate epochs, permanent nullifier reporting, inactive chain rejection |
| `BridgeAdapters.spec`     | Message deduplication, unsupported chain rejection                                                                            |
| `GovernanceTimelock.spec` | Admin-only access, delay enforcement, queue/execute/cancel lifecycle, delay bounds                                            |
| `ComplianceOracle.spec`   | Governance-only blocking, policy monotonicity, auditor management, governance transfer                                        |
| `RelayerFeeVault.spec`    | Relay uniqueness, stake requirements, fee conservation, slash correctness                                                     |
| `MultiSigGovernance.spec` | Threshold bounds, owner-only access, auto-confirm, no double confirm/execute, confirmation counting, self-only governance     |

```bash
# Run with Certora Prover (requires CERTORAKEY)
certoraRun certora/conf/PrivacyPool.conf
certoraRun certora/conf/NullifierRegistry.conf
```

## Substrate Pallet

The `pallet-privacy-pool` provides native Substrate integration:

```rust
// In your runtime's lib.rs
impl pallet_privacy_pool::Config for Runtime {
    type RuntimeEvent = RuntimeEvent;
    type Currency = Balances;
    type TreeDepth = ConstU32<32>;
    type EpochDuration = ConstU32<300>;
    type MaxNullifiersPerEpoch = ConstU32<65536>;
    type RootHistorySize = ConstU32<100>;
    type ParaId = ConstU32<2100>;
    type AppId = ConstU32<1>;
    type WeightInfo = PrivacyPoolWeights;
}
```

See `runtime/` for a complete example runtime.

## ink! Contract (Native Polkadot Wasm)

For non-EVM Polkadot parachains (e.g. Astar's Wasm VM), an ink! smart contract provides the same privacy pool functionality:

```bash
cd ink/privacy-pool
cargo contract build --release
cargo contract upload --suri //Alice
```

## Docker Deployment

```bash
cd docker

# Start relayer + lumora + monitoring stack
docker compose up -d

# View Grafana dashboards at http://localhost:3000
# Prometheus metrics at http://localhost:9191
# Relayer metrics at http://localhost:9090/metrics
```

## Governance & Safety

### Governance Timelock

All privileged operations (parameter changes, contract upgrades, chain registration) are behind a time-delayed governance timelock:

- **Minimum delay**: 1 hour (configurable up to 30 days)
- **Grace period**: 14 days after ETA to execute
- **Two-step admin transfer**: Prevents accidental lockout
- **Queue → Execute → Cancel** lifecycle with full event audit trail

### Emergency Pause (Circuit Breaker)

- **Guardian role**: Can immediately pause contracts (e.g., multisig, automated monitor)
- **Governance-only unpause**: Prevents compromised guardian from griefing
- **Safety valve**: Anyone can unpause after `MAX_PAUSE_DURATION` (7 days)
- **Composable**: Inherit `EmergencyPause` in any contract → use `whenNotPaused` modifier

### Compliance Oracle

- **Address/commitment blocklists**: Governance can block sanctioned addresses or tainted commitments
- **Authorized auditors**: Role-based access for compliance checks with viewing key proofs
- **Policy versioning**: Monotonically increasing policy version for audit trail
- **Configurable**: Compliance checks can be enabled/disabled by governance

### Multi-Sig Governance

The `MultiSigGovernance` contract provides M-of-N multi-signature governance, designed as the admin of the GovernanceTimelock:

- **Submit → Confirm → Execute** proposal lifecycle (auto-confirms for submitter)
- **Revocable confirmations** before execution
- **Self-governance**: Add/remove owners and change threshold via self-referential proposals
- **Automatic threshold adjustment** when removing owners
- **Production pattern**: MultiSig → Timelock → PrivacyPool/EpochManager/etc.

## Subgraph (Event Indexing)

The `subgraph/` directory contains a full [The Graph](https://thegraph.com/) subgraph for indexing on-chain events:

```bash
cd subgraph

# Generate types from ABI
graph codegen

# Deploy to hosted service or Subgraph Studio
graph deploy --studio soul-privacy-stack
```

**Indexed entities**: Deposit, Transfer, Withdrawal, Epoch, CrossChainSync, TimelockTransaction, MerkleTreeState, PoolMetrics (aggregated).

## SDK — Fee Estimator

Estimate withdrawal relay fees before submitting:

```typescript
import { FeeEstimator, AVALANCHE_FUJI } from "soul-privacy-sdk";

const estimator = new FeeEstimator(AVALANCHE_FUJI, {
  relayerFeeVault: "0x...", // optional: reads on-chain fee
  protocolFeeBps: 30, // 0.3% protocol fee
});

const estimate = await estimator.estimateWithdrawFee(parseEther("1"));
console.log("Total fee:", estimate.totalFeeFormatted);
console.log("Net withdrawal:", formatEther(estimate.netWithdrawalWei));
console.log("Economical:", estimate.isEconomical);

// Minimum viable withdrawal
const min = await estimator.minimumEconomicalWithdrawal();
```

## Post-Deploy Verification

After deploying to a new chain, run the verification script to validate all contracts:

```bash
forge script scripts/VerifyDeployment.s.sol --rpc-url $RPC_URL
```

Checks: verifier linkage, epoch manager pool authorization, domain IDs, pause state, merkle tree initialization, timelock delay bounds, cross-contract references.

## EIP-1153 Transient Storage

For chains supporting Cancun (EIP-1153), the `TransientReentrancyGuard` provides ~95% gas savings over traditional `SSTORE`-based reentrancy guards. The `TransientStorage` library offers general-purpose transient read/write helpers.

## SDK — Proof Client

The SDK includes a `ProofClient` for communicating with the Lumora coprocessor:

```typescript
import { ProofClient } from "soul-privacy-sdk";

const prover = new ProofClient({ coprocessorUrl: "http://localhost:8080" });

// Check health
const health = await prover.health();

// Generate a deposit proof
const result = await prover.proveDeposit({
  commitment: "0x...",
  value: parseEther("1"),
  secret: "0x...",
  nonce: "0x...",
});

console.log(result.proof, result.publicInputs);
```

## Documentation

| Document                                               | Description                                                           |
| ------------------------------------------------------ | --------------------------------------------------------------------- |
| [Architecture](docs/ARCHITECTURE.md)                   | Deep-dive into system design, proof pipeline, bridge architecture     |
| [Getting Started](docs/GETTING_STARTED.md)             | Local development setup, first deposit walkthrough                    |
| [Operational Runbook](docs/operations/RUNBOOK.md)      | Startup, health checks, emergency pause, incident response            |
| [MEV Protection Design](docs/design/MEV_PROTECTION.md) | Commit-reveal deposits, private mempool integration                   |
| [ADRs](docs/decisions/)                                | Architecture decision records                                         |
| [Security Policy](SECURITY.md)                         | Vulnerability reporting, proof verification matrix, known limitations |
| [Contributing](CONTRIBUTING.md)                        | Development workflow, style guide, ADR/RFC process                    |

## Security Considerations

- **ZK soundness**: All proofs verified on-chain (Groth16 pairing check or UltraHonk)
- **Nullifier domain separation**: V2 nullifiers include `chain_id` + `app_id` preventing cross-domain replay
- **Sequential epoch validation**: Registry enforces monotonic epoch IDs per chain
- **Bridge message deduplication**: Each adapter tracks processed message hashes
- **Governance timelock**: All privileged operations require time-delayed execution
- **Emergency pause**: Circuit breaker with guardian/governance separation
- **Merkle root history**: 100-root ring buffer prevents front-running by allowing recent-but-not-current roots
- **Metadata resistance**: Relayer supports timing jitter and batching to resist traffic analysis
- **Relayer health monitoring**: `/health`, `/ready`, `/metrics` endpoints for operational observability

## License

MIT
