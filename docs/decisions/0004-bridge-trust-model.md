# 0004 — Bridge Adapter Trust Model

**Status**: Accepted  
**Date**: 2025-11-20  
**Author**: Core team

## Context

Soul Privacy Stack operates across five ecosystems — EVM (Avalanche, Moonbeam),
Substrate (Astar), Cosmos (Evmos), and NEAR (Aurora) — requiring cross-chain
message passing to synchronize epoch roots and relay shielded transfers. Each
ecosystem uses a different bridging primitive:

| Bridge         | Protocol     | Chains                      |
| -------------- | ------------ | --------------------------- |
| Teleporter/AWM | BLS multisig | Avalanche ↔ Moonbeam        |
| XCM            | Relay-chain  | Moonbeam ↔ Astar            |
| IBC            | Light-client | Evmos ↔ Avalanche/Moonbeam  |
| Rainbow Bridge | Light-client | Aurora ↔ Avalanche/Moonbeam |

The trust model for cross-chain operations differs fundamentally from the
trust model for on-chain operations, and must be explicitly designed.

## Decision

### Architecture: Hub-and-Spoke with Relayer Attestation

1. **Avalanche C-Chain is the canonical hub**. All cross-chain epoch root
   updates originate from the Avalanche `PrivacyPool` contract and propagate
   outward via bridge adapters.

2. **Bridge adapters are permissioned**. Each adapter contract
   (`TeleporterAdapter`, `XcmBridgeAdapter`, `IbcBridgeAdapter`,
   `AuroraRainbowAdapter`) is deployed and owned by governance. Only
   governance can update the authorized source chain/contract addresses.

3. **Messages carry a Merkle root and epoch number**. The payload structure is:

   ```
   struct EpochSync {
       uint64 epochNumber;
       bytes32 merkleRoot;
       bytes32 nullifierSetRoot;
   }
   ```

4. **Receiving contracts validate**:
   - Source chain/address matches the authorized bridge adapter
   - Epoch number is strictly monotonically increasing
   - Message is not a replay (tracked via processed-message set)

5. **Relayer role is delivery-only**. Authorized relayers submit transactions
   that trigger bridge message sends, but they **cannot forge** the content.
   The bridge protocol itself guarantees message authenticity. Relayers are
   compensated from `RelayerFeeVault`.

### Trust Assumptions per Bridge

| Bridge         | Trust Assumption                              | Verification    |
| -------------- | --------------------------------------------- | --------------- |
| Teleporter/AWM | Avalanche P-chain BLS stake-weighted multisig | Warp precompile |
| XCM            | Polkadot relay chain consensus                | HRMP channel    |
| IBC            | Light-client header verification              | Tendermint LC   |
| Rainbow Bridge | Ethereum/NEAR light-client on both sides      | Header relay    |

### Future: Light-Client Verification

When production-ready ZK light clients become available, bridge adapters
will be upgraded to verify compact state proofs rather than trusting
external validator sets. This is tracked as a post-v1.0 milestone.

## Consequences

### Positive

- Clear separation: bridge adapters handle transport, pool contracts handle
  verification logic
- Monotonic epoch enforcement prevents root rollback attacks
- Replay protection via processed-message tracking
- Upgrade path to ZK light clients without changing the adapter interface
- Each bridge adapter is independently auditable

### Negative

- Hub-and-spoke creates a dependency on Avalanche C-Chain availability
- Bridge liveness failures delay cross-chain epoch syncs
- Governance key compromise could redirect bridge adapter pointers
- Different bridges have different finality guarantees (IBC ~6s vs
  XCM ~12s vs AWM ~2s), complicating cross-chain consistency
- No atomic cross-chain operations — transfers are eventual-consistency

## Alternatives Considered

1. **Fully trustless ZK bridges** — rejected for v1.0 because no
   production-ready ZK light client supports all five ecosystems.
   Planned as a post-v1.0 upgrade path.
2. **Optimistic bridges with fraud proofs** — rejected because the
   7-day challenge period is unacceptable for privacy pool epoch syncs.
3. **Single canonical bridge** (e.g., LayerZero, Axelar) — rejected
   because it introduces a single point of failure and limits ecosystem
   reach (no native Substrate/Cosmos/NEAR support in most generic bridges).
4. **Peer-to-peer mesh** — rejected because O(n²) bridge pairs are
   impractical to audit and maintain. Hub-and-spoke is O(n).
