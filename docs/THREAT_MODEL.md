# Threat Model — Soul Privacy Stack

**Version:** 0.7.0  
**Last Updated:** 2025  
**Classification:** Public

---

## 1. System Overview

The Soul Privacy Stack is a multi-chain ZK privacy middleware enabling shielded
transactions across EVM chains (Avalanche, Moonbeam, Astar, Evmos, Aurora),
Substrate parachains, CosmWasm chains, and NEAR. Key components:

- **PrivacyPool** — Incremental Merkle tree with ZK deposit/transfer/withdraw
- **EpochManager** — Time-bounded epochs for nullifier root aggregation
- **UniversalNullifierRegistry** — Cross-chain double-spend prevention
- **GovernanceTimelock + MultiSigGovernance** — Upgrade and parameter governance
- **Relayer** — Off-chain service bridging epoch roots across chains
- **Bridge Adapters** — Chain-specific cross-chain message passing
- **Lumora Coprocessor** — Off-chain ZK computation engine
- **SDK** — Client-side proof generation, wallet management, stealth addresses

---

## 2. Trust Assumptions

| Assumption | Description | Impact if Violated |
|------------|-------------|--------------------|
| ZK proof soundness | Proofs cannot be forged without valid witness | Theft of funds |
| Merkle tree integrity | Tree correctly tracks all commitments | Invalid proofs accepted |
| Nullifier uniqueness | Domain-separated nullifiers prevent collisions | Double-spend |
| Governance honesty | Multisig majority does not collude | Contract takeover |
| Relayer liveness | Relayer processes epoch roots in timely manner | Delayed cross-chain transfers |
| Bridge security | Bridge adapters relay authentic messages | Forged epoch roots |
| RNG quality | Client-side randomness for commitments is secure | Commitment correlation |

---

## 3. Threat Categories

### 3.1 Smart Contract Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| SC-1 | Reentrancy on withdraw | Critical | Checks-effects-interactions pattern; state updated before transfer |
| SC-2 | Merkle tree overflow | High | `TREE_DEPTH = 32` supports 4.3B leaves; index bounds check |
| SC-3 | Root history exhaustion | Medium | Circular buffer (`ROOT_HISTORY_SIZE = 100`) overwrites oldest |
| SC-4 | Unauthorized epoch finalization | High | `onlyGovernance` modifier on `finalizeEpoch()` |
| SC-5 | Stale root acceptance | Medium | Root history limits how far back a valid root can be |
| SC-6 | Integer overflow/underflow | High | Solidity 0.8.x built-in overflow checks |
| SC-7 | Selector collision | Low | All function selectors are distinct; verified in tests |
| SC-8 | Proxy storage collision | Medium | No upgradeable proxies currently; governance-only upgrades |

### 3.2 ZK Proof Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| ZK-1 | Proof forgery | Critical | Halo2/Groth16 soundness; binding tag verification |
| ZK-2 | Proof replay (cross-input) | Critical | Fiat-Shamir binding tag ties proof to specific inputs |
| ZK-3 | All-zero proof acceptance | Critical | Explicit zero-proof rejection in all verifiers |
| ZK-4 | Duplicate nullifier in proof | High | Distinct-nullifier check before spending |
| ZK-5 | Zero-value nullifier | High | Non-zero nullifier enforcement |
| ZK-6 | Proof too large (DoS) | Medium | Maximum proof size limits (8KB EVM, 4KB ink!) |
| ZK-7 | Verifier key substitution | Critical | Keys embedded at deploy time; upgrade requires governance |
| ZK-8 | Trusted setup compromise | Critical | Halo2 uses transparent setup (no toxic waste) |

### 3.3 Cross-chain Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| CC-1 | Forged epoch root injection | Critical | Only governance or authorized relayer can sync roots |
| CC-2 | Relayer censorship | High | Governance can replace relayer; fallback manual sync |
| CC-3 | Bridge message replay | Medium | Domain-separated keys: `source_chain_id:epoch_id` |
| CC-4 | Relayer front-running | Medium | Metadata resistance (jitter, batching) |
| CC-5 | Cross-chain nullifier collision | High | V2 domain-separated nullifiers: `keccak256(chainId, appId, secret, leafIndex)` |
| CC-6 | Bridge adapter compromise | Critical | Adapter is upgradeable only by governance |
| CC-7 | Epoch desynchronization | Medium | Aligned epoch durations; tolerance in root history size |

### 3.4 Governance Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| GOV-1 | Governance key compromise | Critical | MultiSig (3-of-5+ recommended); hardware wallets |
| GOV-2 | Timelock bypass | Critical | Hardcoded `MINIMUM_DELAY`; no admin override |
| GOV-3 | Malicious upgrade | Critical | Timelock delay allows community review before execution |
| GOV-4 | EmergencyPause abuse | High | Pause is time-limited; unpause requires governance |
| GOV-5 | Signer collusion | High | Geographically distribute signers; use threshold > N/2 |

### 3.5 Privacy / Metadata Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| P-1 | Transaction graph analysis | High | Pool model obscures sender-receiver links |
| P-2 | Timing correlation | Medium | Relayer jitter and batching |
| P-3 | Amount correlation | Medium | Fixed denominations or shielded amounts |
| P-4 | Deposit/withdraw address linking | High | Stealth address support for recipients |
| P-5 | RPC provider fingerprinting | Medium | SDK should support user-provided RPC endpoints |
| P-6 | Small anonymity set | High | Longer epoch durations increase set size |
| P-7 | Compliance oracle deanonymization | Medium | Oracle only stores compliance attestations, not identities |

### 3.6 Operational Threats

| ID | Threat | Severity | Mitigation |
|----|--------|----------|------------|
| OPS-1 | Relayer private key leak | Critical | Use `env:` secret injection; never commit keys |
| OPS-2 | RPC endpoint DoS | High | Multiple fallback RPC providers per chain |
| OPS-3 | Gas price spike | Medium | `max_gas_price_gwei` safety cap in relayer config |
| OPS-4 | Monitoring blind spots | Medium | Prometheus metrics + Grafana dashboards + alert rules |
| OPS-5 | Deployment artifact mismatch | High | Deployment tracking JSON per chain; verification script |

---

## 4. Attack Scenarios

### 4.1 Double-spend Attack

**Vector:** Attacker tries to use the same nullifier on two different chains.

**Flow:**
1. Attacker deposits on Chain A.
2. Generates withdrawal proof with nullifier N.
3. Submits withdrawal on Chain A (nullifier N marked spent).
4. Before epoch root syncs, submits same proof on Chain B.

**Mitigation:**
- Domain-separated nullifiers include `chainId` and `appId`.
- Cross-chain nullifier roots are synced per epoch.
- `UniversalNullifierRegistry` provides global nullifier tracking.

### 4.2 Forged Root Injection

**Vector:** Compromised bridge relayer injects fake epoch root.

**Flow:**
1. Attacker gains relayer key.
2. Calls `syncEpochRoot()` with fabricated nullifier root.
3. Fabricated root allows previously-spent nullifiers to appear unspent.

**Mitigation:**
- Relayer is authorized by governance multisig.
- Governance can revoke relayer authorization immediately.
- Root history limits damage scope (only recent roots accepted).
- Monitoring alerts on unexpected root syncs.

### 4.3 Proof Replay Attack

**Vector:** Attacker captures a valid proof and replays it with different inputs.

**Flow:**
1. Observe a valid transfer transaction on-chain.
2. Extract the proof and submit with different nullifiers/commitments.

**Mitigation:**
- Fiat-Shamir binding tag in proof first 32 bytes ties proof to specific inputs.
- Verifier recomputes binding and rejects mismatched proofs.

---

## 5. Security Controls Matrix

| Control | SC | ZK | CC | GOV | P | OPS |
|---------|:--:|:--:|:--:|:---:|:--:|:---:|
| Formal verification (Certora) | ✓ | | ✓ | ✓ | | |
| Fuzz testing | ✓ | | | | | |
| Invariant tests | ✓ | ✓ | | | | |
| Unit tests (multi-chain) | ✓ | ✓ | ✓ | ✓ | | |
| Binding tag verification | | ✓ | | | | |
| Domain-separated nullifiers | | ✓ | ✓ | | | |
| MultiSig governance | | | | ✓ | | |
| Timelock delay | | | ✓ | ✓ | | |
| Emergency pause | ✓ | | | ✓ | | |
| Metadata resistance (jitter/batching) | | | | | ✓ | |
| Stealth addresses | | | | | ✓ | |
| Secret management (env vars) | | | | | | ✓ |
| Monitoring & alerting | | | ✓ | | | ✓ |

---

## 6. Residual Risks

| Risk | Likelihood | Impact | Status |
|------|-----------|--------|--------|
| Undiscovered Solidity vulnerability | Low | Critical | Mitigated by Certora specs + fuzz tests |
| Poseidon hash mismatch across chains | Medium | High | Known — domain-tagged keccak256 standin; fix before mainnet |
| Small testnet anonymity sets | High | Medium | Expected for testnet; mainnet will have larger sets |
| Bridge liveness dependency | Medium | Medium | Governance manual sync fallback exists |
| ZK verifier placeholder in NEAR/ink! | High | Critical | Must replace with real verifier before mainnet |

---

## 7. Recommendations

1. **Pre-mainnet audit** — Full audit of Solidity, Rust, and ZK circuits by a reputable firm.
2. **Replace placeholder verifiers** — NEAR and ink! contracts use structural validation; integrate real Groth16/Halo2 verifiers.
3. **Poseidon alignment** — Replace keccak256-based Poseidon standin with BN254 field-arithmetic Poseidon across all chains.
4. **Bug bounty program** — Launch on Immunefi or similar platform post-audit.
5. **Key ceremony** — If migrating to Groth16, conduct a trusted setup ceremony.
6. **Incident response plan** — Document runbook for emergency pause, relayer key rotation, and governance key recovery.
