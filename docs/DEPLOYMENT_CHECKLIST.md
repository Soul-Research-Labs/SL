# Deployment Checklist

Comprehensive step-by-step guide for deploying the Soul Privacy Stack across all supported chains.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Environment Setup](#environment-setup)
3. [Deployment Order](#deployment-order)
4. [Per-Chain EVM Deployment](#per-chain-evm-deployment)
5. [Non-EVM Deployments](#non-evm-deployments)
6. [Post-Deployment Verification](#post-deployment-verification)
7. [Cross-Chain Configuration](#cross-chain-configuration)
8. [Governance Handoff](#governance-handoff)
9. [Operational Readiness](#operational-readiness)

---

## Prerequisites

### Tooling

- [ ] Foundry (forge, cast, anvil) — `curl -L https://foundry.paradigm.xyz | bash`
- [ ] Noir 0.35+ — `noirup -v 0.35.0`
- [ ] Rust 1.75+ with `wasm32-unknown-unknown` target
- [ ] Node.js 18+ and pnpm
- [ ] Docker and Docker Compose
- [ ] `near-cli-rs` for NEAR deployments
- [ ] `wasmd` / `osmosisd` for CosmWasm deployments

### Accounts & Keys

- [ ] Deployer wallet funded on each target chain
- [ ] Hardware wallet or secure key management (never use raw private keys in mainnet deploys)
- [ ] Block explorer API keys for contract verification (Snowtrace, Moonscan, Blockscout, etc.)

### Artifacts

- [ ] All Solidity contracts compiled: `forge build`
- [ ] ZK verifier contracts generated from Noir circuits (see `contracts/verifiers/`)
- [ ] CosmWasm contracts optimized: `docker run --rm -v "$(pwd)/cosmwasm":/code cosmwasm/workspace-optimizer:0.15.0`
- [ ] NEAR contracts compiled: `cd near/contracts && cargo build --target wasm32-unknown-unknown --release`
- [ ] ink! contracts compiled: `cd ink/privacy-pool && cargo contract build --release`

---

## Environment Setup

Copy and fill in the environment file:

```bash
cp .env.example .env
```

Required variables:

| Variable | Description | Example |
|---|---|---|
| `DEPLOYER_PRIVATE_KEY` | Deployer EOA private key (testnet only) | `0xac0974...` |
| `AVAX_RPC_URL` | Avalanche Fuji RPC | `https://api.avax-test.network/ext/bc/C/rpc` |
| `MOONBEAM_RPC_URL` | Moonbase Alpha RPC | `https://rpc.api.moonbase.moonbeam.network` |
| `ASTAR_RPC_URL` | Shibuya RPC | `https://evm.shibuya.astar.network` |
| `EVMOS_RPC_URL` | Evmos Testnet RPC | `https://eth.bd.evmos.dev:8545` |
| `AURORA_RPC_URL` | Aurora Testnet RPC | `https://testnet.aurora.dev` |
| `SNOWTRACE_API_KEY` | Avalanche explorer API key | — |
| `MOONSCAN_API_KEY` | Moonbeam explorer API key | — |
| `VERIFIER_ADDRESS` | Pre-deployed verifier (or `0x0` for placeholder) | `0x...` |
| `GUARDIAN_ADDRESS` | Emergency pause guardian | `0x...` |
| `GOVERNANCE_ADDRESS` | Governance multisig / timelock | `0x...` |

> **Mainnet Safety**: Deploy scripts include a guard that blocks placeholder verifiers on mainnet chain IDs. Always deploy real verifiers first on mainnet.

---

## Deployment Order

Contracts must be deployed in dependency order. Within each chain:

```
1. Verifier (PlonkVerifier / UltraVerifier)
2. EpochManager
3. PrivacyPool (depends on: Verifier, EpochManager)
4. BridgeAdapter (chain-specific; depends on: PrivacyPool)
5. GovernanceTimelock
6. MultiSigGovernance
7. ComplianceOracle
8. RelayerFeeVault
9. StealthAnnouncer
10. UniversalNullifierRegistry
```

Cross-chain setup happens **after all chains are deployed** (see [Cross-Chain Configuration](#cross-chain-configuration)).

---

## Per-Chain EVM Deployment

### Avalanche (Fuji / C-Chain)

```bash
make deploy-fuji
# or manually:
forge script scripts/deploy/DeployAvalanche.s.sol:DeployAvalanche \
  --rpc-url $AVAX_RPC_URL --broadcast --verify
```

- [ ] Verifier deployed
- [ ] EpochManager deployed
- [ ] PrivacyPool deployed and linked to Verifier + EpochManager
- [ ] AvaxWarpAdapter deployed (uses Avalanche Warp Messaging)
- [ ] TeleporterAdapter deployed (optional, for Teleporter-based messaging)
- [ ] Addresses recorded in `deployments/avalanche/addresses.json`
- [ ] Contracts verified on Snowtrace

### Moonbeam (Moonbase Alpha)

```bash
make deploy-moonbase
```

- [ ] Verifier deployed
- [ ] EpochManager deployed
- [ ] PrivacyPool deployed
- [ ] XcmBridgeAdapter deployed (uses XCM for Polkadot interop)
- [ ] Addresses recorded in `deployments/moonbeam/addresses.json`
- [ ] Contracts verified on Moonscan

### Astar (Shibuya)

```bash
make deploy-astar
```

- [ ] Verifier deployed
- [ ] EpochManager deployed
- [ ] PrivacyPool deployed
- [ ] XcmBridgeAdapter deployed
- [ ] Addresses recorded in `deployments/astar/addresses.json`
- [ ] Contracts verified on Blockscout

### Evmos (Testnet)

```bash
make deploy-evmos
```

- [ ] Verifier deployed
- [ ] EpochManager deployed
- [ ] PrivacyPool deployed
- [ ] IbcBridgeAdapter deployed (uses IBC for Cosmos interop)
- [ ] Addresses recorded in `deployments/evmos/addresses.json`
- [ ] Contracts verified

### Aurora (Testnet)

```bash
make deploy-aurora
```

- [ ] Verifier deployed
- [ ] EpochManager deployed
- [ ] PrivacyPool deployed
- [ ] AuroraRainbowAdapter deployed (uses Rainbow Bridge for NEAR interop)
- [ ] Addresses recorded in `deployments/aurora/addresses.json`
- [ ] Contracts verified

---

## Non-EVM Deployments

### NEAR

```bash
make deploy-near
# or manually:
bash scripts/deploy/deploy-near.sh
```

- [ ] WASM contract compiled
- [ ] Contract account created on NEAR testnet
- [ ] Contract deployed and initialized
- [ ] Deposit/withdraw functions tested via `near-cli-rs`

### CosmWasm

```bash
make deploy-cosmwasm
# or manually:
bash scripts/deploy/deploy-cosmwasm.sh
```

- [ ] Contract optimized via workspace-optimizer
- [ ] Code stored on chain (`wasmd tx wasm store`)
- [ ] Contract instantiated with correct parameters
- [ ] Query endpoints verified

### Substrate (ink!)

```bash
cd ink/privacy-pool
cargo contract instantiate --suri //Alice --args ...
```

- [ ] ink! contract compiled (`cargo contract build --release`)
- [ ] Contract instantiated on Substrate testnet
- [ ] Core functions callable

---

## Post-Deployment Verification

Run the automated verification script on each EVM chain:

```bash
# Set addresses from deployments/<chain>/addresses.json
export POOL=0x...
export EPOCH_MANAGER=0x...
export GOVERNANCE=0x...
export VERIFIER=0x...
export COMPLIANCE=0x...

forge script scripts/VerifyDeployment.s.sol:VerifyDeployment \
  --rpc-url $<CHAIN>_RPC_URL
```

### Verification Checks

- [ ] **PrivacyPool**: Correct verifier address, correct epoch manager, domain IDs set, not paused, merkle root initialized, guardian configured
- [ ] **EpochManager**: Authorized pools registered, epoch duration correct
- [ ] **GovernanceTimelock**: Admin set correctly, delay bounds configured
- [ ] **Verifier**: Proving system identifier correct
- [ ] **ComplianceOracle**: Governance address set, policy version > 0

---

## Cross-Chain Configuration

After all chains are deployed:

### 1. Register Cross-Chain Routes

For each BridgeAdapter, register all peer chains:

```bash
# Example: register Moonbeam as a peer on the Avalanche adapter
cast send $AVAX_BRIDGE_ADAPTER "registerChain(uint256,address)" \
  1287 $MOONBEAM_BRIDGE_ADAPTER --rpc-url $AVAX_RPC_URL
```

- [ ] All chain pairs registered bidirectionally
- [ ] Route table documented in deployment addresses

### 2. Configure Cross-Chain Epoch Relay

```bash
# Authorize the relayer to sync epoch roots
cast send $EPOCH_MANAGER "setAuthorizedRelayer(address)" \
  $RELAYER_ADDRESS --rpc-url $<CHAIN>_RPC_URL
```

- [ ] Relayer authorized on all chains
- [ ] Epoch root sync tested across at least one chain pair

### 3. Update Subgraph

```bash
# Update subgraph.yaml with deployed addresses
bash subgraph/configure.sh <chain> <pool_address> <epoch_manager_address>
# Deploy subgraph
cd subgraph && graph deploy --studio soul-privacy-<chain>
```

- [ ] Subgraph deployed per chain
- [ ] Indexing confirmed (check for first events)

---

## Governance Handoff

> **Critical**: Do not skip this section. Deployer EOA must not retain admin privileges in production.

### 1. Deploy Governance Contracts

- [ ] GovernanceTimelock deployed with appropriate delay (testnet: 1 day, mainnet: ≥ 2 days)
- [ ] MultiSigGovernance deployed with quorum threshold

### 2. Transfer Ownership

```bash
# Transfer PrivacyPool governance
cast send $PRIVACY_POOL "transferGovernance(address)" $GOVERNANCE_TIMELOCK

# Transfer EpochManager ownership
cast send $EPOCH_MANAGER "transferOwnership(address)" $GOVERNANCE_TIMELOCK

# Transfer ComplianceOracle governance
cast send $COMPLIANCE_ORACLE "transferGovernance(address)" $GOVERNANCE_TIMELOCK
```

- [ ] PrivacyPool governance transferred to timelock
- [ ] EpochManager ownership transferred
- [ ] ComplianceOracle governance transferred
- [ ] BridgeAdapter governance transferred
- [ ] RelayerFeeVault governance transferred
- [ ] Deployer EOA no longer has admin on any contract

### 3. Verify Governance

- [ ] Timelock delay enforced (test with a proposal)
- [ ] MultiSig quorum verified
- [ ] Emergency pause still functional via guardian (separate from governance)

---

## Operational Readiness

### Infrastructure

- [ ] Relayer running and connected to all chains (`docker compose up relayer`)
- [ ] Lumora Coprocessor running (`docker compose up lumora`)
- [ ] Prometheus scraping all endpoints
- [ ] Grafana dashboards accessible and showing data
- [ ] Alert rules configured (see `monitoring/alerts/`)

### Monitoring Thresholds

- [ ] Epoch finalization latency < threshold
- [ ] Relayer gas balance alerts set
- [ ] Nullifier registry size monitoring
- [ ] Cross-chain message acknowledgment tracking

### Documentation

- [ ] `deployments/<chain>/addresses.json` fully populated with deployed addresses, tx hashes, and block numbers
- [ ] Operations runbook reviewed (`docs/operations/RUNBOOK.md`)
- [ ] Incident response contacts documented
- [ ] On-call rotation established

### Smoke Test

Run the E2E integration test against the live testnet:

```bash
forge script scripts/E2EIntegration.s.sol:E2EIntegration \
  --rpc-url $<CHAIN>_RPC_URL --broadcast
```

- [ ] Deposit succeeds
- [ ] Epoch finalizes
- [ ] Transfer succeeds (if applicable)
- [ ] Withdrawal succeeds
- [ ] Cross-chain relay functions

---

## Mainnet Deployment Differences

| Aspect | Testnet | Mainnet |
|---|---|---|
| Verifier | Placeholder allowed | **Real ZK verifier required** |
| Epoch duration | Short (for testing) | Production cadence (e.g., 1 hour) |
| Governance delay | 1 day | ≥ 2 days |
| MultiSig quorum | 1-of-N | ≥ 3-of-5 |
| Guardian | Dev EOA | Dedicated security multisig |
| Key management | `.env` file | Hardware wallet / KMS |
| Deploy method | `--private-key` | `--ledger` or `--trezor` |

---

## Rollback Procedure

If deployment fails mid-way:

1. **Do not** attempt to redeploy over existing contracts
2. Record which contracts were successfully deployed
3. Assess whether partial deployment can be completed or must be abandoned
4. If abandoning: pause all deployed contracts via guardian, document the failed state
5. Redeploy from scratch with fresh addresses if necessary

> Contracts are not upgradeable by default. Plan migrations carefully.
