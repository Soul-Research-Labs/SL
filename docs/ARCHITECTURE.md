# Soul Privacy Stack — Architecture

> A multi-chain ZK privacy middleware enabling private transactions across 9+
> chains spanning five ecosystems.

---

## High-Level Overview

```
                          ┌─────────────────────┐
                          │   SDK (TS / Python)  │
                          │  NoteWallet, Stealth │
                          └──────────┬──────────┘
                                     │ proof request
                                     ▼
                          ┌─────────────────────┐
                          │  Lumora Coprocessor  │
                          │  Halo2 IPA → Groth16│
                          └──────────┬──────────┘
                                     │ proof envelope
                                     ▼
                          ┌─────────────────────┐
                          │   Relayer Daemon     │
                          │  batch, submit, fee  │
                          └──────────┬──────────┘
                ┌────────────────────┼────────────────────┐
                ▼                    ▼                     ▼
        ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
        │  EVM Chains   │  │  Substrate   │  │  CosmWasm / NEAR │
        │  (Solidity)   │  │  (Pallet)    │  │  (Rust wasm)     │
        └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘
               │                 │                    │
               └─────────────────┴────────────────────┘
                          Bridge Adapters
                     (AWM, XCM, IBC, Rainbow)
```

---

## Core Modules

### 1. Privacy Pool

**Purpose**: Holds shielded notes. Users deposit, transfer, and withdraw using
ZK proofs. Each operation creates/consumes commitments in a depth-32 Merkle
tree.

| Platform  | Implementation                     | Verifier             |
| --------- | ---------------------------------- | -------------------- |
| EVM       | `contracts/core/PrivacyPool.sol`   | Groth16 on-chain     |
| Substrate | `pallets/privacy-pool/`            | Halo2 IPA in-pallet  |
| CosmWasm  | `cosmwasm/contracts/privacy-pool/` | Groth16 host binding |
| NEAR      | `near/contracts/privacy-pool/`     | Groth16 host binding |
| ink!      | `ink/privacy-pool/`                | Cross-contract call  |

**State model**:

```
Note = { commitment, value, secret, nullifier_key }
Commitment = Poseidon(value, secret, nullifier_key)
Nullifier  = Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))   [V2]
```

### 2. Merkle Tree

**File**: `contracts/libraries/MerkleTree.sol`

- Fixed depth of 32 (supports ~4 billion leaves)
- Poseidon T=3 hash function (BN254 scalar field)
- On-chain root history (ring buffer of 100 recent roots) for async withdrawal
- `insertLeaf()` returns the leaf index and new root

### 3. Nullifier System

**File**: `contracts/libraries/DomainNullifier.sol`

Two generations:

- **V1** (deprecated): `Poseidon(secret, commitment)` — no domain separation
- **V2** (current): `Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`
  - Chain-scoped: same note → different nullifier per chain
  - App-scoped: different app IDs for pool vs. stealth vs. compliance

**Global registry**: `contracts/core/UniversalNullifierRegistry.sol` provides
cross-chain nullifier deduplication. Only authorized submitters (pool contracts,
relayers) can register nullifiers.

### 4. Epoch Manager

**File**: `contracts/core/EpochManager.sol`

- Partitions time into fixed-duration epochs (default 3600s / 1 hour)
- Each epoch finalizes a snapshot of the Merkle root + nullifier set
- `advanceEpoch()` — advances the epoch (relayer or governance)
- `receiveRemoteRoot(epoch, sourceChain, root)` — ingests roots from other chains
- Cross-chain root sync ensures all chains share the same privacy set timeline

### 5. Compliance Oracle

**File**: `contracts/core/ComplianceOracle.sol`

- Configurable blocklist (OFAC/sanctions addresses)
- Viewing-key verification: privacy pool can optionally require compliance proof
- Enhanced due diligence (EDD) threshold for large deposits
- Toggle-able per environment (disabled for testnets)

### 6. Governance

**Files**: `contracts/core/GovernanceTimelock.sol`, `contracts/core/MultiSigGovernance.sol`

- **Timelock**: Queue → wait delay → execute pattern. Delay range: 1 hour (testnet) to 30 days (mainnet).
- **MultiSig**: M-of-N threshold approval for governance actions, emergency pause, parameter updates.

### 7. Emergency Pause

**File**: `contracts/core/EmergencyPause.sol`

- Guardian-triggered circuit breaker: freezes all pool operations instantly
- Bypass for governance-only unpause
- Integrates with all bridge adapters

---

## Proof System

### Circuit Pipeline

```
User Input  →  Noir Circuit  →  Halo2 IPA Proof  →  Groth16 SNARK Wrapper  →  On-chain
              (constraint def)   (Lumora off-chain)   (256-bit, ~250K gas)     (verify)
```

### Noir Circuits (`noir/circuits/`)

| Circuit           | Purpose                              | Public Inputs                      |
| ----------------- | ------------------------------------ | ---------------------------------- |
| `deposit`         | Proves valid commitment construction | commitment, value                  |
| `transfer`        | Proves spend + re-commitment         | root, nullifiers[2], newCms[2]     |
| `withdraw`        | Proves spend authority + amount      | root, nullifier, recipient, amount |
| `nullifier_check` | Proves nullifier domain separation   | nullifier, chain_id, app_id        |
| `stealth`         | Proves stealth address derivation    | stealth_addr, ephemeral_pubkey     |

### Halo2 Circuits (`lumora-coprocessor/src/`)

- `circuit.rs` — `TransferCircuit` and `WithdrawCircuit` using Halo2 IPA
- `proof.rs` — `ProofGenerator` orchestrates proving with optional Groth16 wrapper
- Uses `light-poseidon` crate with `ark-bn254` for real Poseidon hashing

### Verification Stack

| Layer         | Component                | Gas/Weight Cost    |
| ------------- | ------------------------ | ------------------ |
| SNARK Wrapper | `Halo2SnarkVerifier.sol` | ~250K gas (EVM)    |
| Fallback      | `UltraHonkVerifier.sol`  | ~350K gas (EVM)    |
| Substrate     | Pallet verifier (IPA)    | ~600M weight parts |
| CosmWasm/NEAR | Host function binding    | ~200K gas equiv    |

---

## Bridge Architecture

Cross-chain state sync is handled by dedicated bridge adapters per ecosystem:

```
Chain A (PrivacyPool)                     Chain B (PrivacyPool)
        │                                         ▲
        │ epochRoot + nullifierBatch               │
        ▼                                         │
  BridgeAdapter.send()  ──[ bridge msg ]──>  BridgeAdapter.receive()
        │                                         │
        └──────────> EpochManager.receiveRemoteRoot()
```

| Adapter                    | Bridge Protocol              | Trust Model                   |
| -------------------------- | ---------------------------- | ----------------------------- |
| `AvaxWarpAdapter.sol`      | Avalanche Warp Messaging     | BLS 67% subnet validators     |
| `TeleporterAdapter.sol`    | Teleporter (AWM abstraction) | Same + higher-level relay     |
| `XcmBridgeAdapter.sol`     | Polkadot XCM                 | Relay chain consensus         |
| `IbcBridgeAdapter.sol`     | IBC (Cosmos)                 | Tendermint light client proof |
| `AuroraRainbowAdapter.sol` | Rainbow Bridge (NEAR)        | NEAR light client on Ethereum |

### Bridge Message Format

```solidity
struct BridgeMessage {
    uint256 sourceChainId;
    uint256 epochId;
    bytes32 epochRoot;         // Merkle root snapshot
    bytes32 nullifierRoot;     // Nullifier accumulator
    bytes32[] nullifierBatch;  // New nullifiers this epoch
}
```

---

## Relayer (`relayer/`)

The relayer daemon is a Rust service that:

1. **Polls** Lumora for completed proofs
2. **Batches** proof submissions per chain (configurable batch size)
3. **Submits** on-chain transactions to PrivacyPool contracts
4. **Syncs** epoch roots across chains via bridge adapters
5. **Reports** metrics to Prometheus (relay count, failure rate, gas used)

**Anti-metadata features** (configurable in `config.toml`):

- Submission jitter (randomized delay)
- Dummy transaction padding
- Batch size randomization

---

## Stealth Addresses

**File**: `contracts/core/StealthAnnouncer.sol`, `sdk/src/stealth.ts`

- Dual-key stealth address scheme (spending key + viewing key)
- `StealthAnnouncer` contract stores ephemeral public keys on-chain
- Recipients scan announcements using their viewing key
- Compatible with ERC-5564 stealth address standard

---

## Data Flow: Deposit → Transfer → Withdraw

```
1. DEPOSIT
   User → SDK.buildDepositTx(value, secret)
        → PrivacyPool.deposit(commitment, value)
        → MerkleTree.insertLeaf(commitment) → new root
        → emit Deposit(commitment, leafIndex, value, newRoot)

2. TRANSFER (shielded)
   User → SDK.proveTransfer(inputNotes, outputNotes)
        → Lumora.generateTransfer(circuit_inputs)
        → ProofEnvelope { raw_proof, snark_wrapper, public_inputs }
        → Relayer.submitProof(proof, root, nullifiers, newCommitments)
        → PrivacyPool.transfer(proof, root, nullifier[2], newCm[2])
        → verify proof + spend nullifiers + insert new commitments

3. WITHDRAW
   User → SDK.proveWithdraw(note, recipient, amount)
        → Lumora.generateWithdraw(circuit_inputs)
        → Relayer.submitWithdraw(proof, root, nullifier, recipient, amount)
        → PrivacyPool.withdraw(proof, root, nullifier, outputCm, recipient, amount)
        → verify proof + spend nullifier + send ETH/token to recipient
```

---

## Directory Map

```
contracts/
  core/             PrivacyPool, EpochManager, ComplianceOracle, Governance,
                    EmergencyPause, StealthAnnouncer, RelayerFeeVault,
                    UniversalNullifierRegistry
  bridges/          AvaxWarp, Teleporter, XCM, IBC, Rainbow adapters
  interfaces/       IBridgeAdapter, IComplianceOracle, IPrivacyPool, etc.
  libraries/        MerkleTree, DomainNullifier, PoseidonHasher, ProofEnvelope
  verifiers/        Halo2SnarkVerifier, UltraHonkVerifier

pallets/            Substrate FRAME pallet (Polkadot)
ink/                ink! smart contract (Polkadot WASM VM)
cosmwasm/           CosmWasm contract (Cosmos SDK chains)
near/               NEAR Protocol contract

lumora-coprocessor/ Off-chain Halo2 proof generation service
relayer/            Cross-chain relayer daemon
noir/circuits/      Noir ZK circuit definitions

sdk/                TypeScript SDK (viem-based)
sdks/python/        Python SDK (web3.py-based)

subgraph/           The Graph subgraph for indexing pool events
docker/             Docker Compose (relayer + lumora + prometheus + grafana)
monitoring/         Prometheus alert rules
scripts/deploy/     Per-chain deployment scripts
certora/            Formal verification specs (7 modules)
test/               Foundry tests (unit, fuzz, fork, integration)
```

---

## Technology Versions

| Component      | Version / Toolchain |
| -------------- | ------------------- |
| Solidity       | 0.8.24              |
| Foundry        | latest              |
| Rust           | ≥ 1.75              |
| Noir           | 0.35                |
| Substrate      | polkadot-sdk 1.x    |
| ink!           | 5.x                 |
| CosmWasm       | cosmwasm-std 2.x    |
| NEAR SDK       | 5.x                 |
| TypeScript SDK | viem 2.20           |
| Python SDK     | web3.py ≥ 7         |
| Prometheus     | 2.53.0              |
| Grafana        | 11.1.0              |
