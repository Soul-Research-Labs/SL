# 0001 — Nullifier Domain Separation V2

**Status**: Accepted  
**Date**: 2025-06-15  
**Author**: Core team

## Context

The V1 nullifier scheme `Poseidon(secret, commitment)` produced the same
nullifier for a given note regardless of which chain or application consumed it.
This meant:

1. A note spent on Chain A could **not** be independently spent on Chain B
   (good for single-chain), but there was no structural guarantee — it relied on
   the global nullifier registry being synchronized in real-time.
2. If the same privacy pool contract was deployed on multiple chains with the
   same nullifier registry, a timing gap between cross-chain sync could allow
   double-spends.
3. Applications sharing a pool (e.g. pool vs. stealth announcer) could not
   enforce independent nullifier namespaces.

## Decision

Adopt V2 domain-separated nullifiers:

```
nullifier = Poseidon(
    Poseidon(spending_key, commitment),
    Poseidon(chain_id, app_id)
)
```

Where:

- `spending_key` — user's private nullifier key
- `commitment` — the note commitment being consumed
- `chain_id` — EVM chain ID (e.g., 43113 for Fuji)
- `app_id` — application identifier (1 = privacy pool, 2 = stealth, etc.)

## Consequences

### Positive

- Same note → different nullifier on each chain → no cross-chain replay
  even during sync gaps
- Application isolation — stealth announcer nullifiers cannot collide with pool nullifiers
- Enables "same UTXO on multiple chains" patterns for future cross-chain
  atomic swaps

### Negative

- V1 nullifiers are incompatible; migration required for existing notes
- Two Poseidon calls instead of one per nullifier computation (~2× gas for
  nullifier verification)
- `UniversalNullifierRegistry` must store chain_id + app_id metadata alongside
  nullifier hashes

## Alternatives Considered

1. **Simple chain_id prefix**: `Poseidon(chain_id, secret, commitment)` — rejected
   because it doesn't separate applications within the same chain.
2. **Keccak domain tag**: `keccak256(chain_id || app_id || Poseidon(sk, cm))` —
   rejected because mixing hash functions weakens the algebraic binding
   properties needed for ZK circuit constraints.
3. **Incremental nullifier**: Sequential counter per note — rejected because it
   leaks ordering information.
