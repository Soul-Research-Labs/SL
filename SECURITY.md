# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly.

**DO NOT** open a public GitHub issue for security vulnerabilities.

### Contact

Email: **security@soul-privacy.dev** (replace with your actual security contact)

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Impact assessment (which contracts/modules are affected)
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: within 48 hours
- **Initial assessment**: within 1 week
- **Fix & disclosure**: coordinated within 90 days

---

## Security Architecture

### ZK Proof Verification

| Component    | Proof System          | Verification Location                          |
| ------------ | --------------------- | ---------------------------------------------- |
| EVM Chains   | Halo2 → Groth16 SNARK | `Halo2SnarkVerifier.sol` (on-chain, ~250K gas) |
| EVM Fallback | UltraHonk (Noir)      | `UltraHonkVerifier.sol` (on-chain)             |
| Substrate    | Halo2 IPA             | Pallet verifier (on-chain, FRAME weight)       |
| CosmWasm     | Halo2 → Groth16       | Contract `verify_proof()`                      |
| Near         | Halo2 → Groth16       | Contract `verify_proof()`                      |

### Nullifier Safety

- **Domain separation V2**: `Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`
- Same note → different nullifier per chain → no cross-chain replay
- `UniversalNullifierRegistry.sol` provides global nullifier deduplication
- Sequential epoch enforcement prevents out-of-order root submissions

### Bridge Security Model

| Bridge         | Trust Model                              | Authentication             |
| -------------- | ---------------------------------------- | -------------------------- |
| Avalanche AWM  | BLS multi-sig (67% of subnet validators) | Warp message signature     |
| Teleporter     | AWM + higher-level abstraction           | Teleporter relay signature |
| Polkadot XCM   | Relay chain consensus                    | XCM message authentication |
| IBC            | Light client proof                       | Tendermint consensus proof |
| Rainbow Bridge | Near light client on Ethereum            | Block header proof         |

### Access Control

- **Governance-gated operations**: Chain registration, adapter configuration, compliance policy updates, relayer slashing
- **Relayer staking**: Minimum stake required for relay participation; slashing for misbehavior
- **Compliance oracle**: Configurable blocklist, viewing-key auditing, toggle-able per environment

### Known Limitations

1. **Placeholder verifiers**: Current on-chain verifiers contain placeholder logic for development. Production deployment requires generating actual verification keys from the Noir/Halo2 circuits.

2. **Poseidon constants**: Solidity `PoseidonHasher` uses example round constants. Production requires constants generated from the canonical Poseidon specification for BN254.

3. **Substrate Poseidon**: The pallet uses `keccak256` as a placeholder. Production requires integrating `poseidon-rs` or the Lumora Poseidon crate.

4. **Bridge trust assumptions**: Cross-ecosystem routes (e.g., Avalanche → Polkadot) currently rely on the relayer's honesty. Adding light-client verification for cross-ecosystem bridges would strengthen this.

5. **MEV consideration**: Deposits and withdrawals are visible on-chain. Miners/validators could front-run or censor transactions. Consider using private mempools or commit-reveal schemes.

### Audit Status

- [ ] External audit (pending)
- [ ] Formal verification via Certora (specs written, execution pending)
- [ ] Fuzzing campaign (Foundry invariant tests)
- [ ] Circuit audit (Noir + Halo2 soundness review)

---

## Dependency Security

### Solidity

- Solidity 0.8.24 (overflow protection built-in)
- No external dependencies beyond forge-std (testing only)
- All contracts are self-contained

### Rust

- Dependencies pinned to specific versions in `Cargo.toml`
- `cargo audit` should be run before each release
- Substrate pallets use official Polkadot SDK versions

### TypeScript SDK

- `viem` for type-safe EVM interactions (no unsafe `ethers` patterns)
- No server-side code — SDK is client-only

---

## Responsible Disclosure

We follow coordinated disclosure. Fixes will be released before public disclosure. Reporters who follow responsible disclosure will be credited (with permission) in the advisory.
