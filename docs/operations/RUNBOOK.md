# Soul Privacy Stack — Operational Runbook

> **Audience**: Operators, SREs, and on-call engineers.

---

## Table of Contents

1. [Service Architecture](#service-architecture)
2. [Startup & Shutdown](#startup--shutdown)
3. [Health Checks](#health-checks)
4. [Emergency Pause](#emergency-pause)
5. [Relayer Operations](#relayer-operations)
6. [Lumora Coprocessor Operations](#lumora-coprocessor-operations)
7. [Epoch Management](#epoch-management)
8. [Key Management](#key-management)
9. [Monitoring & Alerting](#monitoring--alerting)
10. [Incident Response](#incident-response)
11. [Upgrade Procedures](#upgrade-procedures)

---

## 1. Service Architecture

```
SDK (TS/Python)
      │
      ▼
 Lumora Coprocessor (Halo2 + Groth16 wrapper)
      │
      ▼
 Relayer ──► Privacy Pools (EVM / Substrate / CosmWasm / NEAR / ink!)
      │
      ├── EpochManager
      ├── ComplianceOracle
      ├── NullifierRegistry
      └── RelayerFeeVault
```

- **Lumora** listens on HTTP (default `:8080`) for proof generation requests.
- **Relayer** polls Lumora, batches proofs, and submits on-chain transactions.
- **Prometheus + Grafana** provide monitoring via Docker Compose.

---

## 2. Startup & Shutdown

### Docker Compose (recommended)

```bash
# Start all services
cd docker && docker compose up -d

# View logs
docker compose logs -f relayer lumora

# Graceful shutdown (waits for in-flight proofs)
docker compose down --timeout 30
```

### Manual

```bash
# Lumora coprocessor
RUST_LOG=lumora_coprocessor=info lumora-coprocessor serve --port 8080

# Relayer
RUST_LOG=relayer=info relayer run --config config.toml
```

Both services handle `SIGINT` / `SIGTERM` for graceful shutdown.

---

## 3. Health Checks

| Service | Endpoint      | Expected Response                  |
| ------- | ------------- | ---------------------------------- |
| Lumora  | `GET /health` | `{"status":"ok","prover":"halo2"}` |
| Relayer | `GET /health` | `{"status":"ok"}`                  |

Use liveness probes in Kubernetes or Docker healthchecks:

```yaml
# Docker Compose example
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  interval: 15s
  timeout: 5s
  retries: 3
```

---

## 4. Emergency Pause

The `EmergencyPause` contract allows a privileged guardian to freeze all pool
operations instantly.

### Trigger Pause

```bash
# Using cast (Foundry)
cast send $EMERGENCY_PAUSE_ADDRESS "pause()" \
  --rpc-url $RPC_URL \
  --private-key $GUARDIAN_KEY
```

### Verify Pause State

```bash
cast call $EMERGENCY_PAUSE_ADDRESS "paused()(bool)" --rpc-url $RPC_URL
```

### Resume Operations

```bash
cast send $EMERGENCY_PAUSE_ADDRESS "unpause()" \
  --rpc-url $RPC_URL \
  --private-key $GUARDIAN_KEY
```

### When to Pause

- Evidence of proof forgery or nullifier collision
- Compromised relayer private key
- On-chain vulnerability disclosure (pre-patch)
- Bridge adapter exploit
- Unexpected root divergence between chains

**After pausing**: immediately begin [Incident Response](#10-incident-response).

---

## 5. Relayer Operations

### Configuration

The relayer reads `config.toml` (see `relayer/config.example.toml`).

Key settings:

- `rpc_urls`: RPC endpoints per chain (use failover arrays)
- `private_key`: Relayer submission key (see [Key Management](#8-key-management))
- `batch_size`: Number of proofs to batch per transaction
- `gas_limit_multiplier`: Safety margin for gas estimation

### Common Tasks

**Check relayer balance:**

```bash
cast balance $RELAYER_ADDRESS --rpc-url $RPC_URL
```

**Manually relay a stuck transaction:**

```bash
# Bump gas and resubmit
cast send $POOL_ADDRESS "submitProof(bytes,bytes32[])" $PROOF $INPUTS \
  --rpc-url $RPC_URL \
  --private-key $RELAYER_KEY \
  --gas-price $(cast gas-price --rpc-url $RPC_URL | awk '{print $1 * 1.5}')
```

**Monitor pending relay queue:**
Check Prometheus metric `relay_queue_depth`.

---

## 6. Lumora Coprocessor Operations

### Proving Keys

Keys must be placed in the `keys/` directory relative to the working directory:

- `keys/transfer.pk` — Transfer circuit proving key
- `keys/withdraw.pk` — Withdraw circuit proving key
- `keys/snark_wrapper.pk` — (Optional) Groth16 wrapper proving key

If keys are missing, the coprocessor runs in **testnet mode** using placeholder
keys. This produces structurally valid but cryptographically non-binding proofs.

### Performance Tuning

- Increase `--workers` for higher throughput (default 4).
- Each worker uses ~2 GB RAM during proof generation.
- Monitor `proof_generation_duration_seconds` histogram in Prometheus.

### Troubleshooting

| Symptom                      | Likely Cause                  | Fix                                       |
| ---------------------------- | ----------------------------- | ----------------------------------------- |
| `Worker panic` errors        | OOM during proof gen          | Reduce workers or increase RAM            |
| Slow proofs (>30s)           | CPU-bound, insufficient cores | Scale horizontally                        |
| `Proving key not found` logs | Missing key files             | Place `.pk` files in `keys/`              |
| SNARK wrapper disabled       | Missing `snark_wrapper.pk`    | Expected in testnet; required for mainnet |

---

## 7. Epoch Management

Epochs partition time for Merkle root finalization. The `EpochManager` contract
tracks epoch boundaries.

```bash
# Current epoch
cast call $EPOCH_MANAGER "currentEpoch()(uint256)" --rpc-url $RPC_URL

# Advance epoch (permissioned — only callable by governance or relayer)
cast send $EPOCH_MANAGER "advanceEpoch()" \
  --rpc-url $RPC_URL --private-key $RELAYER_KEY
```

**Alert**: If `NoEpochsReceived` fires, check:

1. Relayer is running and funded
2. RPC endpoint is reachable
3. EpochManager contract is not paused

---

## 8. Key Management

### Relayer Key

- Store the relayer private key in a secrets manager (AWS Secrets Manager,
  HashiCorp Vault, GCP Secret Manager).
- Rotate quarterly or immediately after any security incident.
- The relayer key should only have permission to call `submitProof`, `advanceEpoch`,
  and `submitNullifier` — never pool admin functions.

### Guardian Key (Emergency Pause)

- Cold-store the guardian key (hardware wallet or multi-sig).
- Use the `MultiSigGovernance` contract for multi-party emergency actions.
- Minimum 3-of-5 signers for production.

### Proving Keys

- Generated from the trusted setup ceremony.
- Store in a secure, versioned artifact store.
- Verify checksum before loading: `sha256sum keys/transfer.pk`.

---

## 9. Monitoring & Alerting

### Stack

- **Prometheus** scrapes metrics from relayer (`:9090`) and Lumora (`:8080`).
- **Grafana** dashboards at `:3000`.
- Alert rules defined in `monitoring/alerts.yml`.

### Key Metrics

| Metric                              | Description               | Alert Threshold           |
| ----------------------------------- | ------------------------- | ------------------------- |
| `relay_failures_total`              | Failed relay transactions | >5% failure rate over 10m |
| `relay_last_success_timestamp`      | Last successful relay     | No success in 15m         |
| `epoch_finalized_total`             | Epochs finalized on-chain | No epoch in 30m           |
| `proof_generation_duration_seconds` | Proof gen latency         | p99 >60s                  |

### Grafana Dashboard Setup

Import the provided dashboard JSON (when available) or create panels for:

1. Relay success/failure rate (counter)
2. Proof generation latency (histogram)
3. Epoch progression (gauge)
4. Relayer balance per chain (gauge)

---

## 10. Incident Response

### Severity Levels

| Level  | Description   | Response Time     | Example                            |
| ------ | ------------- | ----------------- | ---------------------------------- |
| **P0** | Funds at risk | Immediate         | Proof forgery, nullifier collision |
| **P1** | Service down  | 15 minutes        | Relayer crash loop, RPC failure    |
| **P2** | Degraded      | 1 hour            | Slow proofs, missed epochs         |
| **P3** | Minor         | Next business day | Dashboard gap, log noise           |

### P0 Playbook (Funds at Risk)

1. **Pause immediately**: Trigger `EmergencyPause` on ALL chains.
2. **Notify**: Alert all signers, security team, and bridge operators.
3. **Assess**: Determine which proofs/nullifiers are affected.
4. **Contain**: Disable relayer, revoke bridge permissions if needed.
5. **Investigate**: Collect logs, on-chain events, proof artifacts.
6. **Remediate**: Deploy fix via `GovernanceTimelock` (minimum 48h delay for mainnet).
7. **Post-mortem**: Document root cause, timeline, and preventive measures.

### P1 Playbook (Service Down)

1. **Diagnose**: Check `docker compose ps`, health endpoints, RPC connectivity.
2. **Restart**: `docker compose restart relayer lumora`.
3. **Escalate if not resolved in 15 minutes**: Check Prometheus for root cause.
4. **Failover**: Switch to backup RPC endpoints in config.

### Communication Template

```
[INCIDENT] Soul Privacy Stack — P{N} — {Brief Description}

Status: Investigating / Mitigating / Resolved
Impact: {What is affected}
Start time: {UTC timestamp}
Current actions: {What is being done}
Next update: {ETA}
```

---

## 11. Upgrade Procedures

### Smart Contract Upgrades

1. Submit upgrade proposal via `GovernanceTimelock`:
   ```bash
   cast send $TIMELOCK "queueTransaction(address,uint256,string,bytes,uint256)" \
     $TARGET 0 "upgradeTo(address)" $(cast abi-encode "f(address)" $NEW_IMPL) $ETA \
     --rpc-url $RPC_URL --private-key $PROPOSER_KEY
   ```
2. Wait for timelock delay to expire.
3. Execute the queued transaction.
4. Verify via deployment verification script:
   ```bash
   forge script scripts/VerifyDeployment.s.sol --rpc-url $RPC_URL
   ```

### Relayer / Lumora Upgrades

1. Build new Docker image and tag.
2. Pull and restart with zero downtime:
   ```bash
   docker compose pull relayer lumora
   docker compose up -d --no-deps relayer lumora
   ```
3. Verify health endpoints return `200 OK`.
4. Monitor for 15 minutes before considering complete.

### Proving Key Updates (Circuit Upgrade)

1. Run new trusted setup ceremony.
2. Place new keys in `keys/` directory.
3. Restart Lumora coprocessor.
4. Verify old proofs are still valid during migration window.
5. Deploy new on-chain verifiers pointing to new VKs.
