# 0002 — Proof System Selection: Halo2 IPA + Noir

**Status**: Accepted  
**Date**: 2025-09-10  
**Author**: Core team

## Context

The privacy pool requires zero-knowledge proofs for deposits, transfers, and
withdrawals. Multiple proof systems are available with different trade-offs:

| System | Trusted Setup | Proof Size | Verification Gas | Curves |
|--------|--------------|------------|-----------------|--------|
| Groth16 | Required (per-circuit) | ~200 B | ~200k gas | BN254 |
| Halo2 (KZG) | Universal SRS | ~1–3 KB | ~300k gas | BN254 |
| Halo2 (IPA) | None (transparent) | ~3–10 KB | ~500k gas | Pasta/BN254 |
| PLONK (Aztec) | Universal SRS | ~500 B | ~250k gas | BN254 |
| Nova/folding | None | Varies | Varies | Pasta |

Key requirements:

1. **No trusted setup** — The project cannot coordinate a multi-party ceremony
   at launch. A transparent scheme eliminates this operational risk.
2. **Multi-chain deployment** — Proofs must verify on EVM, Substrate WASM,
   CosmWasm, NEAR, and ink!. A universal proof format is preferred.
3. **Circuit development velocity** — The team needs rapid iteration on five
   circuits (deposit, transfer, withdraw, nullifier_check, stealth).
4. **Auditability** — Simpler constraint systems are easier to audit.

## Decision

Use a two-layer proof architecture:

1. **Circuit DSL**: Noir (Aztec) for writing all five circuits. Noir compiles
   to ACIR (Abstract Circuit Intermediate Representation) which is backend-agnostic.
2. **Backend**: Halo2 with IPA commitment scheme (transparent — no trusted setup).
3. **On-chain verification**: A lightweight SNARK wrapper (Halo2→Groth16 or
   Halo2→UltraHonk) compresses the IPA proof for cheaper on-chain verification.
   The wrapper uses a universal SRS (powers of tau from Zcash/Hermez ceremonies).

The proof flow:

```
Noir circuit → ACIR → Halo2 IPA proving → IPA proof
    → SNARK wrapper → compressed proof → on-chain verifier
```

## Consequences

### Positive

- No per-circuit trusted setup; only the universal SRS (already public)
- Noir's high-level language accelerates circuit development and auditing
- ACIR backend portability: if a better prover emerges, circuits don't change
- IPA proofs can also be verified natively on Substrate (no EVM gas concern)
- Fiat-Shamir binding tag provides transcript integrity across all platforms

### Negative

- IPA proofs are larger than Groth16: 3–10 KB vs ~200 bytes
- SNARK wrapper adds a second verification layer (complexity)
- On-chain verification gas is higher than pure Groth16 (~500k with wrapper)
- Fewer off-the-shelf verifier contracts exist for Halo2 IPA

## Alternatives Considered

1. **Pure Groth16** — rejected because it requires a per-circuit trusted setup
   ceremony, which is operationally infeasible at launch.
2. **PLONK with KZG** — considered but rejected because KZG still requires a
   universal SRS ceremony (though reusable). The Halo2 IPA transparent option
   was preferred for stronger trust assumptions.
3. **Nova folding** — too experimental for production; folding schemes lack
   mature verifier implementations on EVM.
