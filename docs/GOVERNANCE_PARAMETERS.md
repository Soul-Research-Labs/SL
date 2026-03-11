# Governance Parameter Defaults

Reference for all governance, epoch, and safety parameters across the Soul Privacy Stack.

---

## EVM Contracts (Solidity)

### GovernanceTimelock

Controls the delay between proposal queuing and execution.

| Parameter       | Value           | Type     | Notes                                              |
| --------------- | --------------- | -------- | -------------------------------------------------- |
| `MINIMUM_DELAY` | 1 hour          | Constant | Shortest allowed timelock                          |
| `MAXIMUM_DELAY` | 30 days         | Constant | Longest allowed timelock                           |
| `GRACE_PERIOD`  | 14 days         | Constant | Window after delay expires before tx becomes stale |
| `delay`         | Constructor arg | Variable | Must be within [MINIMUM_DELAY, MAXIMUM_DELAY]      |

**Recommended testnet delay:** 1 hour (fast iteration)  
**Recommended mainnet delay:** 48 hours (sufficient review window)

### MultiSigGovernance

Manages proposal creation, confirmation, and execution.

| Parameter   | Value           | Type     | Notes                                                            |
| ----------- | --------------- | -------- | ---------------------------------------------------------------- |
| `threshold` | Constructor arg | Variable | Minimum confirmations to execute (1 ≤ threshold ≤ owners.length) |
| `owners`    | Constructor arg | Array    | List of signer addresses                                         |

**Recommended testnet config:** 2-of-3 multisig  
**Recommended mainnet config:** 3-of-5 or 4-of-7 multisig (no single point of failure)

### EpochManager

Manages epoch lifecycle and cross-chain root propagation.

| Parameter       | Value                       | Type      | Notes                             |
| --------------- | --------------------------- | --------- | --------------------------------- |
| `epochDuration` | Constructor arg (immutable) | `uint256` | Seconds per epoch                 |
| `domainChainId` | Constructor arg (immutable) | `uint32`  | Domain-separated chain identifier |

**Current deployment value:** 3600 seconds (1 hour) across all chains.

**Recommended values by environment:**

| Environment | Duration    | Rationale                            |
| ----------- | ----------- | ------------------------------------ |
| Local/dev   | 60s         | Fast feedback loops                  |
| Testnet     | 3600s (1h)  | Realistic timing without long waits  |
| Mainnet     | 21600s (6h) | Balance privacy set size vs. latency |

> **Note:** Shorter epochs mean smaller anonymity sets per epoch. Longer epochs increase
> cross-chain sync latency. The 6-hour mainnet recommendation balances both concerns.

### PrivacyPool (Solidity)

| Parameter           | Value | Type     | Notes                              |
| ------------------- | ----- | -------- | ---------------------------------- |
| `TREE_DEPTH`        | 32    | Constant | Supports 2^32 ≈ 4.3 billion leaves |
| `ROOT_HISTORY_SIZE` | 100   | Constant | Circular buffer of recent roots    |

---

## Substrate Runtime

Parameters configured in `runtime/src/lib.rs` for the Polkadot parachain deployment.

| Parameter               | Value      | Type            | Notes                        |
| ----------------------- | ---------- | --------------- | ---------------------------- |
| `TreeDepth`             | 32         | Config constant | Merkle tree depth            |
| `EpochDuration`         | 300 blocks | Config constant | ~30 min at 6s block time     |
| `MaxNullifiersPerEpoch` | 65,536     | Config constant | Overflow protection          |
| `RootHistorySize`       | 100        | Config constant | Historical root buffer       |
| `ParaId`                | 2100       | Config constant | Parachain identifier         |
| `AppId`                 | 1          | Config constant | Application domain separator |

---

## NEAR Contract

| Parameter                  | Value           | Type     | Notes                                  |
| -------------------------- | --------------- | -------- | -------------------------------------- |
| `TREE_DEPTH`               | 32              | Constant | Merkle tree depth                      |
| `ROOT_HISTORY_SIZE`        | 100             | Constant | Circular buffer of recent roots        |
| `MAX_NULLIFIERS_PER_EPOCH` | 10,000          | Constant | Epoch overflow guard                   |
| `domain_chain_id`          | Constructor arg | `u32`    | Domain separator (e.g., 1313 for NEAR) |
| `domain_app_id`            | Constructor arg | `u32`    | Application domain separator           |

---

## ink! Contract (Polkadot WASM)

| Parameter           | Value           | Type     | Notes                           |
| ------------------- | --------------- | -------- | ------------------------------- |
| `TREE_DEPTH`        | 32              | Constant | Merkle tree depth               |
| `ROOT_HISTORY_SIZE` | 100             | Constant | Circular buffer of recent roots |
| `epoch_duration`    | Constructor arg | `u32`    | Blocks per epoch                |

---

## Cross-chain Consistency Rules

1. **Tree depth** must be identical (32) across all chains for proof compatibility.
2. **Root history size** should be >= 100 to handle relay delays.
3. **Domain chain IDs** must be unique per deployment to prevent cross-chain nullifier collisions:
   - Avalanche Fuji: 43113
   - Moonbase Alpha: 1287
   - Shibuya (Astar): 81
   - Evmos Testnet: 9000
   - Aurora Testnet: 1313161555
   - Substrate Parachain: 2100
   - NEAR Testnet: 1313
4. **Epoch durations** should be aligned across chains (or at integer multiples)
   to simplify cross-chain root synchronization.

---

## Parameter Change Process

All governance parameter changes on mainnet should follow:

1. **Proposal** — Submit via MultiSigGovernance with rationale.
2. **Review** — All signers review the parameter change impact.
3. **Timelock** — Queue via GovernanceTimelock (minimum delay applies).
4. **Execution** — Execute after delay within the grace period.
5. **Verification** — Verify on-chain state matches expected values.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the ADR/RFC process for protocol-level changes.
