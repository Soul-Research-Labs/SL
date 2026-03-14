# Key Management & Rotation Procedures

> **Audience**: Security team, DevOps, on-call engineers.
> **Last updated**: 2026-03-14

---

## Key Inventory

| Key Role               | Access Level       | Storage          | Rotation Cadence  | Holders                  |
| ---------------------- | ------------------ | ---------------- | ----------------- | ------------------------ |
| Deployer EOA           | Full admin (temp)  | Hardware wallet  | Once (not reused) | Deployment team          |
| Governance Multisig    | Admin (timelock)   | Hardware wallets | N/A (signers)     | 5+ governance signers    |
| Guardian (Pause)       | Emergency pause    | Cold storage     | Annually          | Security team            |
| Relayer Submission Key | submitProof, epoch | Secrets manager  | Quarterly         | Automated (no human use) |
| Lumora Signing Key     | Proof submission   | Secrets manager  | Quarterly         | Automated                |
| Subgraph Deploy Token  | Subgraph deploy    | CI secrets       | On compromise     | Deploy pipeline          |

---

## Storage Requirements

### Hardware Wallets (Governance & Guardian Keys)

- Use Ledger Nano X or Trezor Model T.
- Backup seed phrases stored in geographically separated locations.
- Never store seed phrases digitally (no photos, no cloud, no password managers).
- Label each device with its role (e.g., "governance-signer-3").

### Secrets Managers (Relayer & Lumora Keys)

Supported backends (in order of preference):

1. **HashiCorp Vault** — Preferred. Use transit secrets engine for signing.
2. **AWS Secrets Manager** — With IAM role-based access, no long-lived credentials.
3. **GCP Secret Manager** — With Workload Identity for GKE deployments.

Configuration in `relayer/config.toml`:

```toml
[keys]
# Option 1: Vault (recommended)
provider = "vault"
vault_addr = "https://vault.internal:8200"
secret_path = "secret/data/relayer/submission-key"

# Option 2: AWS Secrets Manager
# provider = "aws"
# secret_arn = "arn:aws:secretsmanager:us-east-1:123456789:secret:relayer-key"

# Option 3: Environment variable (testnet only — never use on mainnet)
# provider = "env"
# env_var = "RELAYER_PRIVATE_KEY"
```

---

## Rotation Procedures

### Relayer Key Rotation (Quarterly)

**Pre-rotation checklist:**

- [ ] New key generated in secrets manager
- [ ] New key funded on all target chains (>0.1 native token per chain)
- [ ] Maintenance window scheduled (rotation requires brief pause)

**Procedure:**

```bash
# 1. Generate new key in Vault
vault kv put secret/relayer/submission-key-new \
  private_key="$(cast wallet new | grep 'Private Key' | awk '{print $3}')"

# 2. Extract new address
NEW_RELAYER=$(vault kv get -field=address secret/relayer/submission-key-new)

# 3. Fund new key on all chains
for CHAIN in avalanche moonbeam astar evmos aurora; do
  cast send --value 0.5ether $NEW_RELAYER --rpc-url $${CHAIN^^}_RPC_URL
done

# 4. Authorize new relayer on all EpochManagers
for CHAIN in avalanche moonbeam astar evmos aurora; do
  cast send $EPOCH_MANAGER "setAuthorizedRelayer(address)" $NEW_RELAYER \
    --rpc-url $${CHAIN^^}_RPC_URL
done

# 5. Update relayer config (zero-downtime: new config loaded on restart)
vault kv put secret/relayer/submission-key "$NEW_KEY_DATA"

# 6. Restart relayer
docker compose restart relayer

# 7. Verify new key is active
curl -s http://relayer:9090/health | jq '.relayer_address'

# 8. Revoke old relayer authorization (after confirming new key works)
for CHAIN in avalanche moonbeam astar evmos aurora; do
  cast send $EPOCH_MANAGER "revokeRelayer(address)" $OLD_RELAYER \
    --rpc-url $${CHAIN^^}_RPC_URL
done
```

### Guardian Key Rotation (Annual)

1. Generate new guardian address on a fresh hardware wallet.
2. Submit governance proposal to update guardian on all contracts:
   ```
   PrivacyPool.setGuardian(newGuardian)
   ```
3. Wait for timelock delay (48h on mainnet).
4. Execute governance proposal.
5. Test emergency pause with new guardian key.
6. Securely destroy the old hardware wallet.

### Governance Signer Replacement

When a governance multisig signer leaves:

1. New signer generates key on hardware wallet.
2. Existing signers submit proposal to add new signer and remove old signer.
3. Threshold verification: ensure quorum still achievable (e.g., 3-of-5).
4. Test: submit and execute a no-op proposal with the new signer set.

---

## Key Compromise Response

### Relayer Key Compromised

**Risk**: Attacker can submit spam transactions (gas drain), but cannot steal funds.

1. Immediately rotate key (follow Relayer Key Rotation above).
2. Revoke old key's authorization on all EpochManagers.
3. Monitor for unexpected on-chain activity from old address.
4. No emergency pause needed (relayer cannot access pool funds).

### Guardian Key Compromised

**Risk**: Attacker can pause the protocol but not steal funds.

1. Invoke `GovernanceTimelock` to rotate guardian address.
2. If pool is maliciously paused, governance can unpause via timelock.
3. Rotate guardian key immediately.
4. If timelock delay is too slow, multi-sig can unpause directly.

### Governance Key Compromised (Critical)

**Risk**: Attacker can modify pool parameters after timelock delay.

1. **Immediately**: Monitor all pending timelock transactions.
2. Cancel any unauthorized queued proposals.
3. If quorum is still achievable with remaining honest signers, rotate attacker's key.
4. If quorum is lost, trigger emergency pause via guardian.
5. Deploy new governance contracts and migrate.

---

## Proving Key Management

### Verification

Before loading proving keys into Lumora:

```bash
# Verify transfer proving key checksum
sha256sum keys/transfer.pk
# Expected: <hash from ceremony transcript>

# Verify withdrawal proving key checksum
sha256sum keys/withdraw.pk
# Expected: <hash from ceremony transcript>
```

### Versioning

- Store proving keys in a versioned artifact registry (e.g., S3 with versioning).
- Tag each key set with the circuit version: `v1.0.0-transfer.pk`.
- Lumora config specifies key version explicitly:
  ```toml
  [proving_keys]
  transfer = "s3://soul-keys/v1.0.0/transfer.pk"
  withdraw = "s3://soul-keys/v1.0.0/withdraw.pk"
  ```
- Never overwrite a published proving key — always publish with a new version tag.

---

## Access Control Matrix

| Action                     | Deployer (temp) | Governance    | Guardian | Relayer | Lumora |
| -------------------------- | --------------- | ------------- | -------- | ------- | ------ |
| Deploy contracts           | ✅              | —             | —        | —       | —      |
| Upgrade parameters         | —               | ✅ (timelock) | —        | —       | —      |
| Emergency pause            | —               | ✅            | ✅       | —       | —      |
| Submit proofs on-chain     | —               | —             | —        | ✅      | —      |
| Advance epochs             | —               | —             | —        | ✅      | —      |
| Generate ZK proofs         | —               | —             | —        | —       | ✅     |
| Set denominations          | —               | ✅ (timelock) | —        | —       | —      |
| Withdraw from FeeVault     | —               | ✅ (timelock) | —        | —       | —      |
| Register cross-chain route | —               | ✅ (timelock) | —        | —       | —      |
