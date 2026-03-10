//! Weight estimates for the Privacy Pool pallet.
//!
//! These are placeholder weights. In production, use `frame_benchmarking`
//! to derive accurate weights from actual ZK verification execution times.
//!
//! Expected real-world weights (based on Lumora benchmarks):
//! - deposit: ~10ms (Merkle insertion only)
//! - transfer: ~50-100ms (proof verification [k=13] + Merkle ops)
//! - withdraw: ~50-100ms (proof verification [k=13] + Merkle ops + balance transfer)
//! - finalize_epoch: ~5-50ms (depends on nullifier count)
//! - sync_epoch_root: ~1ms (storage write only)

use frame_support::weights::Weight;

/// Placeholder weight implementation
pub struct SubstrateWeightInfo;

impl super::pallet::WeightInfo for SubstrateWeightInfo {
    fn deposit() -> Weight {
        // Merkle tree insertion (32 hash operations) + storage writes
        Weight::from_parts(50_000_000, 10_000)
    }

    fn transfer() -> Weight {
        // ZK proof verification + Merkle tree operations
        // Halo2 k=13 verification: ~5-10ms on standard hardware
        // Substrate weight: conservative estimate
        Weight::from_parts(500_000_000, 20_000)
    }

    fn withdraw() -> Weight {
        // ZK proof verification + Merkle tree ops + currency transfer
        Weight::from_parts(600_000_000, 25_000)
    }

    fn finalize_epoch() -> Weight {
        // Compute nullifier root (depends on count, capped by MaxNullifiersPerEpoch)
        Weight::from_parts(200_000_000, 15_000)
    }

    fn sync_epoch_root() -> Weight {
        // Simple storage write
        Weight::from_parts(10_000_000, 5_000)
    }
}
