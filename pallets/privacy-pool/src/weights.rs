//! Weight estimates for the Privacy Pool pallet.
//!
//! These are conservative placeholder weights pending real benchmarking.
//! Run the following to generate production weights:
//!
//! ```sh
//! cargo build --release --features runtime-benchmarks
//! frame-benchmarking-cli benchmark pallet \
//!   --chain dev \
//!   --pallet pallet_privacy_pool \
//!   --extrinsic "*" \
//!   --steps 50 \
//!   --repeat 20 \
//!   --output pallets/privacy-pool/src/weights.rs \
//!   --template .maintain/frame-weight-template.hbs
//! ```
//!
//! Expected real-world weights (based on Lumora benchmarks):
//! - deposit: ~10ms (Merkle insertion only)
//! - transfer: ~50-100ms (proof verification [k=13] + Merkle ops)
//! - withdraw: ~50-100ms (proof verification [k=13] + Merkle ops + balance transfer)
//! - finalize_epoch: ~5-50ms (depends on nullifier count)
//! - sync_epoch_root: ~1ms (storage write only)
//!
//! ## Weight Breakdown Methodology
//!
//! Each weight is decomposed into:
//! - **ref_time**: Computational cost in reference time units (picoseconds)
//! - **proof_size**: Maximum proof size (PoV) contribution in bytes
//!
//! Estimation basis:
//! - 1 storage read: ~25µs ref_time, ~32 bytes proof_size
//! - 1 storage write: ~100µs ref_time, ~32 bytes proof_size
//! - 1 Blake2b hash: ~5µs ref_time
//! - Merkle path (depth 32): 32 hashes + 32 reads + 1 write
//! - Proof deser + verify (k=13 Halo2): ~50ms ref_time
//! - Balance transfer: ~50µs ref_time

use frame_support::weights::Weight;

/// Placeholder weight implementation.
///
/// IMPORTANT: Replace with auto-generated weights before mainnet.
/// See module docs for the benchmarking command.
pub struct SubstrateWeightInfo;

impl super::pallet::WeightInfo for SubstrateWeightInfo {
    /// Weight for `deposit` extrinsic.
    ///
    /// Operations:
    /// - 1 read: commitment existence check
    /// - 1 write: store commitment
    /// - 32 reads + 32 writes: Merkle path update (tree depth 32)
    /// - 32 hashes: Poseidon/Blake2b for each level
    /// - 1 write: update root history
    /// - 1 write: update next_leaf_index
    /// - 1 write: reserve deposit amount
    fn deposit() -> Weight {
        // 33 reads × 25µs + 35 writes × 100µs + 32 hashes × 5µs = ~4.5ms
        Weight::from_parts(50_000_000, 10_000)
    }

    /// Weight for `transfer` extrinsic.
    ///
    /// Operations:
    /// - 1 read: root history lookup (up to 100 iterations)
    /// - 2 reads: nullifier spent checks
    /// - 2 writes: mark nullifiers spent
    /// - 1 proof deserialization + verification (~50ms)
    /// - 2× Merkle insertion (2 outputs): 2 × (32R + 32W + 32H)
    /// - 2 writes: update root history, epoch nullifiers
    fn transfer() -> Weight {
        // Proof verification dominates: ~50ms + 2 Merkle insertions ~9ms
        Weight::from_parts(500_000_000, 20_000)
    }

    /// Weight for `withdraw` extrinsic.
    ///
    /// Same as transfer plus:
    /// - 1 read: pool balance check
    /// - 1 write: update pool balance
    /// - 1 balance transfer (Currency::transfer)
    fn withdraw() -> Weight {
        Weight::from_parts(600_000_000, 25_000)
    }

    /// Weight for `finalize_epoch` extrinsic.
    ///
    /// Operations:
    /// - 1 read: current epoch info
    /// - N reads: epoch nullifiers (N = nullifier_count, max 65536)
    /// - N hashes: compute nullifier root
    /// - 2 writes: finalize epoch, create new epoch
    /// - 1 write: update current_epoch_id
    ///
    /// In practice, N is bounded and a single 200ms allocation covers the
    /// maximum nullifier count. Real benchmarks will show linear scaling.
    fn finalize_epoch() -> Weight {
        Weight::from_parts(200_000_000, 15_000)
    }

    /// Weight for `sync_epoch_root` extrinsic.
    ///
    /// Operations:
    /// - 1 read: governance/relayer authorization check
    /// - 1 write: store remote epoch root
    fn sync_epoch_root() -> Weight {
        Weight::from_parts(10_000_000, 5_000)
    }
}
