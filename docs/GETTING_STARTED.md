# Getting Started — Local Testnet Development

This guide walks you through setting up a local development environment,
deploying the privacy stack, and executing your first shielded transaction.

---

## Prerequisites

| Tool         | Install Command                                                           | Verify             |
| ------------ | ------------------------------------------------------------------------- | ------------------ |
| Foundry      | `curl -L https://foundry.paradigm.xyz \| bash && foundryup`               | `forge --version`  |
| Rust ≥ 1.75  | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh`         | `rustc --version`  |
| Node.js ≥ 18 | [nodejs.org](https://nodejs.org/) or `brew install node`                  | `node --version`   |
| Docker       | [docker.com](https://www.docker.com/get-started)                          | `docker --version` |
| Nargo ≥ 0.35 | [noir-lang.org](https://noir-lang.org/docs/getting_started/installation/) | `nargo --version`  |

---

## 1. Clone and Build

```bash
git clone <repo-url> && cd soul-privacy-stack

# Build all components
make build

# This runs:
#   forge build              (Solidity contracts)
#   cargo build --workspace  (Rust: relayer, lumora, pallet, cosmwasm, near)
#   cd sdk && npm run build  (TypeScript SDK)
#   nargo build per circuit  (Noir circuits)
```

---

## 2. Run Tests

```bash
# All tests (Solidity + Rust + SDK)
make test

# Individual test suites
make test-sol            # Foundry tests (all Solidity)
make test-rust           # Cargo tests (entire Rust workspace)
make test-sdk            # Jest (TypeScript SDK)
make test-noir           # Noir circuit tests

# Specialized tests
make test-sol-gas        # Gas benchmarks with report
make test-sol-invariant  # Invariant / fuzz tests
make test-sol-fuzz       # Fuzz tests (MerkleTree, DomainNullifier)
make test-sol-fork       # Fork tests (requires RPC URLs)
```

---

## 3. Start the Infrastructure Stack

```bash
cd docker && docker compose up -d
```

This starts:

- **Lumora coprocessor** at `http://localhost:8080`
- **Relayer** daemon
- **Prometheus** at `http://localhost:9090`
- **Grafana** at `http://localhost:3000` (default admin/admin)

Verify:

```bash
curl http://localhost:8080/health
# → {"status":"ok","prover":"halo2","snarkWrapper":"groth16","circuitVersion":"0.1.0"}
```

---

## 4. Deploy to a Local Anvil Chain

```bash
# Terminal 1: Start local Anvil instance
anvil --chain-id 43113

# Terminal 2: Deploy
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script scripts/deploy/DeployAvalanche.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Note the deployed contract addresses from the console output.

---

## 5. Your First Deposit

Using `cast` (Foundry's CLI):

```bash
# Set contract addresses from deployment output
export POOL=<PrivacyPool address>
export EPOCH=<EpochManager address>

# Generate a commitment (in practice, the SDK does this)
COMMITMENT=$(cast keccak "my_secret_note_1")

# Deposit 0.1 ETH into the privacy pool
cast send $POOL "deposit(bytes32,uint256)" $COMMITMENT 100000000000000000 \
  --value 0.1ether \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $DEPLOYER_PRIVATE_KEY

# Verify the deposit
cast call $POOL "poolBalance()(uint256)" --rpc-url http://127.0.0.1:8545
# → 100000000000000000

cast call $POOL "getLatestRoot()(bytes32)" --rpc-url http://127.0.0.1:8545
# → 0x... (non-zero root)
```

---

## 6. Using the TypeScript SDK

```bash
cd sdk && npm install
```

```typescript
import { createPublicClient, http } from "viem";
import {
  SoulPrivacyClient,
  NoteWallet,
  AVALANCHE_FUJI,
} from "@soul-privacy/sdk";

// Update chain config with your deployed addresses
const config = {
  ...AVALANCHE_FUJI,
  contracts: {
    privacyPool: "0x...", // from deployment output
    epochManager: "0x...",
    proofVerifier: "0x...",
    bridgeAdapter: "0x...",
  },
};

const client = new SoulPrivacyClient(config);
const wallet = new NoteWallet();

// Create a note
const note = wallet.createNote(0.1);

// Build deposit transaction
const depositTx = await client.buildDepositTx(note.commitment, 0.1);
```

---

## 7. Deploy to a Live Testnet

### Avalanche Fuji

```bash
export FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
export DEPLOYER_PRIVATE_KEY=<your-testnet-key>

# Get testnet AVAX from https://faucet.avax.network/
make deploy-fuji
```

### Moonbase Alpha

```bash
export MOONBASE_RPC_URL=https://rpc.api.moonbase.moonbeam.network
make deploy-moonbase
```

### All Chains

See `scripts/deploy/` for deploy scripts for each chain. After deployment,
update `deployments/<chain>/addresses.json` with the deployed addresses.

---

## 8. Project Structure Quick Reference

| Directory             | What              | Build                                  |
| --------------------- | ----------------- | -------------------------------------- |
| `contracts/`          | Solidity (EVM)    | `forge build`                          |
| `pallets/`            | Substrate pallet  | `cargo build -p pallet-privacy-pool`   |
| `cosmwasm/`           | CosmWasm contract | `cargo build -p cosmwasm-privacy-pool` |
| `near/`               | NEAR contract     | `cargo build -p near-privacy-pool`     |
| `ink/`                | ink! contract     | `cargo contract build`                 |
| `lumora-coprocessor/` | Proof gen service | `cargo build -p lumora-coprocessor`    |
| `relayer/`            | Relay daemon      | `cargo build -p soul-relayer`          |
| `noir/circuits/`      | ZK circuits       | `nargo build` per circuit              |
| `sdk/`                | TypeScript SDK    | `cd sdk && npm run build`              |
| `sdks/python/`        | Python SDK        | `pip install -e sdks/python`           |

---

## 9. Useful Commands

```bash
# Format all code
make fmt

# Lint everything
make lint

# Solidity coverage report
make coverage

# Run formal verification (requires CERTORAKEY)
make verify-all

# Build Docker images
make docker-build

# View relayer logs
docker compose -f docker/docker-compose.yml logs -f relayer
```

---

## Next Steps

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for a deep-dive into the system design
- Read [operations/RUNBOOK.md](operations/RUNBOOK.md) for operational procedures
- Read [../SECURITY.md](../SECURITY.md) for the security model and known limitations
- Read [../CONTRIBUTING.md](../CONTRIBUTING.md) for the contribution workflow
