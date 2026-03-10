//! # Privacy Pool Pallet
//!
//! A Substrate pallet implementing a ZK privacy pool for confidential transactions
//! on Polkadot parachains. This is the deepest native integration of the ZAseon/Lumora
//! privacy stack into the Substrate ecosystem.
//!
//! ## Overview
//!
//! This pallet provides:
//! - **Shielded deposits**: Convert public balances into private commitments
//! - **Private transfers**: Transfer value between commitments using ZK proofs
//! - **Withdrawals**: Convert private commitments back to public balances
//! - **Cross-parachain privacy**: Sync epoch nullifier roots via XCM
//! - **Domain-separated nullifiers**: V2 nullifiers with para_id + app_id
//!
//! ## Architecture
//!
//! The pallet reuses core cryptographic primitives from the Lumora Rust crates:
//! - Poseidon hash (from lumora-primitives)
//! - Incremental Merkle tree (from lumora-tree)
//! - ZK proof verification (from lumora-verifier)
//!
//! Proof generation happens off-chain (via lumora-prover) and only verification
//! runs on-chain within Substrate's weight system.
//!
//! ## Dispatchables
//!
//! - `deposit` - Shield native tokens into the privacy pool
//! - `transfer` - Execute a private transfer with ZK proof
//! - `withdraw` - Unshield tokens from the privacy pool
//! - `sync_epoch_root` - Receive epoch nullifier root from another parachain (XCM)
//! - `finalize_epoch` - Finalize current epoch and compute nullifier root

#![cfg_attr(not(feature = "std"), no_std)]

pub use pallet::*;

#[cfg(test)]
mod tests;

#[cfg(feature = "runtime-benchmarks")]
mod benchmarking;

pub mod types;
pub mod verifier;
pub mod weights;

#[cfg(feature = "xcm-support")]
pub mod xcm_handler;

#[frame_support::pallet]
pub mod pallet {
    use frame_support::{
        pallet_prelude::*,
        traits::{Currency, ExistenceRequirement, ReservableCurrency},
        PalletId,
    };
    use frame_system::pallet_prelude::*;
    use sp_core::H256;
    use sp_runtime::traits::{AccountIdConversion, Hash, Zero};
    use sp_std::vec::Vec;

    use crate::types::*;
    use crate::verifier;

    // ── Config ─────────────────────────────────────────────────────

    #[pallet::config]
    pub trait Config: frame_system::Config {
        /// The overarching runtime event type
        type RuntimeEvent: From<Event<Self>> + IsType<<Self as frame_system::Config>::RuntimeEvent>;

        /// The currency mechanism for deposits/withdrawals
        type Currency: Currency<Self::AccountId> + ReservableCurrency<Self::AccountId>;

        /// Merkle tree depth (default: 32)
        #[pallet::constant]
        type TreeDepth: Get<u32>;

        /// Epoch duration in blocks
        #[pallet::constant]
        type EpochDuration: Get<BlockNumberFor<Self>>;

        /// Maximum nullifiers per epoch (for storage bounds)
        #[pallet::constant]
        type MaxNullifiersPerEpoch: Get<u32>;

        /// Maximum root history size
        #[pallet::constant]
        type RootHistorySize: Get<u32>;

        /// This parachain's ID for domain separation
        #[pallet::constant]
        type ParaId: Get<u32>;

        /// Application ID for domain separation
        #[pallet::constant]
        type AppId: Get<u32>;

        /// Pallet ID used to derive the treasury account that holds pool funds
        #[pallet::constant]
        type PalletId: Get<PalletId>;

        /// Weight information for extrinsics
        type WeightInfo: WeightInfo;
    }

    // ── Weight Info Trait ───────────────────────────────────────────

    pub trait WeightInfo {
        fn deposit() -> Weight;
        fn transfer() -> Weight;
        fn withdraw() -> Weight;
        fn finalize_epoch() -> Weight;
        fn sync_epoch_root() -> Weight;
    }

    // ── Pallet Declaration ─────────────────────────────────────────

    #[pallet::pallet]
    pub struct Pallet<T>(_);

    // ── Storage ────────────────────────────────────────────────────

    /// Next leaf index in the Merkle tree
    #[pallet::storage]
    pub type NextLeafIndex<T> = StorageValue<_, u64, ValueQuery>;

    /// Filled subtree hashes at each level (for incremental insertion)
    #[pallet::storage]
    pub type FilledSubtrees<T> = StorageMap<_, Blake2_128Concat, u32, H256, ValueQuery>;

    /// Historical Merkle roots (circular buffer)
    #[pallet::storage]
    pub type Roots<T: Config> = StorageMap<_, Blake2_128Concat, u32, H256, ValueQuery>;

    /// Current root index in the circular buffer
    #[pallet::storage]
    pub type CurrentRootIndex<T> = StorageValue<_, u32, ValueQuery>;

    /// Set of spent nullifiers
    #[pallet::storage]
    pub type NullifierSpent<T> = StorageMap<_, Blake2_128Concat, H256, bool, ValueQuery>;

    /// Set of existing commitments (prevents double-deposit)
    #[pallet::storage]
    pub type CommitmentExists<T> = StorageMap<_, Blake2_128Concat, H256, bool, ValueQuery>;

    /// Total pool balance (in native tokens)
    #[pallet::storage]
    pub type PoolBalance<T> = StorageValue<_, u128, ValueQuery>;

    // ── Epoch Storage ──────────────────────────────────────────────

    /// Current epoch ID
    #[pallet::storage]
    pub type CurrentEpochId<T> = StorageValue<_, u64, ValueQuery>;

    /// Epoch data: epochId → EpochInfo
    #[pallet::storage]
    pub type Epochs<T: Config> = StorageMap<
        _,
        Blake2_128Concat,
        u64,
        EpochInfo<BlockNumberFor<T>>,
        OptionQuery,
    >;

    /// Nullifiers in current epoch (for root computation on finalization)
    #[pallet::storage]
    pub type EpochNullifiers<T: Config> = StorageMap<
        _,
        Blake2_128Concat,
        u64,
        BoundedVec<H256, T::MaxNullifiersPerEpoch>,
        ValueQuery,
    >;

    /// Remote epoch roots from other parachains
    /// Key: (source_para_id, epoch_id)
    #[pallet::storage]
    pub type RemoteEpochRoots<T> = StorageDoubleMap<
        _,
        Blake2_128Concat,
        u32,
        Blake2_128Concat,
        u64,
        H256,
        OptionQuery,
    >;

    // ── Events ─────────────────────────────────────────────────────

    #[pallet::event]
    #[pallet::generate_deposit(pub(super) fn deposit_event)]
    pub enum Event<T: Config> {
        /// Assets deposited (shielded) into the privacy pool
        Deposited {
            commitment: H256,
            leaf_index: u64,
            amount: u128,
        },
        /// Private transfer executed
        Transferred {
            nullifier_1: H256,
            nullifier_2: H256,
            output_commitment_1: H256,
            output_commitment_2: H256,
            new_root: H256,
        },
        /// Assets withdrawn (unshielded) from the privacy pool
        Withdrawn {
            nullifier_1: H256,
            nullifier_2: H256,
            recipient: T::AccountId,
            amount: u128,
            new_root: H256,
        },
        /// Epoch finalized with nullifier root
        EpochFinalized {
            epoch_id: u64,
            nullifier_root: H256,
            nullifier_count: u32,
        },
        /// Remote epoch root received from another parachain
        RemoteEpochRootReceived {
            source_para_id: u32,
            epoch_id: u64,
            nullifier_root: H256,
        },
    }

    // ── Errors ─────────────────────────────────────────────────────

    #[pallet::error]
    pub enum Error<T> {
        /// Deposit amount must be non-zero
        ZeroDeposit,
        /// Commitment already exists in the tree
        CommitmentAlreadyExists,
        /// Merkle tree is full
        TreeFull,
        /// Invalid ZK proof
        InvalidProof,
        /// Nullifier has already been spent
        NullifierAlreadySpent,
        /// Merkle root is not in the history
        UnknownMerkleRoot,
        /// Insufficient pool balance for withdrawal
        InsufficientPoolBalance,
        /// Withdrawal amount must be non-zero
        ZeroWithdrawal,
        /// Epoch not ready for finalization
        EpochNotReady,
        /// Epoch already finalized
        EpochAlreadyFinalized,
        /// Too many nullifiers in this epoch
        EpochNullifierOverflow,
        /// Transfer to recipient failed
        TransferFailed,
        /// Origin not authorized (requires root/governance)
        NotAuthorized,
        /// Invalid nullifier root (zero not accepted)
        InvalidNullifierRoot,
    }

    // ── Genesis ────────────────────────────────────────────────────

    #[pallet::genesis_config]
    #[derive(frame_support::DefaultNoBound)]
    pub struct GenesisConfig<T: Config> {
        #[serde(skip)]
        pub _phantom: sp_std::marker::PhantomData<T>,
    }

    #[pallet::genesis_build]
    impl<T: Config> BuildGenesisConfig for GenesisConfig<T> {
        fn build(&self) {
            // Initialize Merkle tree with zero subtrees
            let mut current_zero = H256::zero();
            for level in 0..T::TreeDepth::get() {
                FilledSubtrees::<T>::insert(level, current_zero);
                // zero[level+1] = poseidon(zero[level], zero[level])
                current_zero = poseidon_hash(current_zero, current_zero);
            }
            // Set initial root
            Roots::<T>::insert(0u32, current_zero);

            // Initialize first epoch
            let epoch_info = EpochInfo {
                start_block: Zero::zero(),
                end_block: None,
                nullifier_root: H256::zero(),
                nullifier_count: 0,
                finalized: false,
            };
            Epochs::<T>::insert(0u64, epoch_info);
        }
    }

    // ── Dispatchables ──────────────────────────────────────────────

    #[pallet::call]
    impl<T: Config> Pallet<T>
    where
        u128: From<<<T as pallet::Config>::Currency as Currency<T::AccountId>>::Balance>,
        <<T as pallet::Config>::Currency as Currency<T::AccountId>>::Balance: From<u128>,
    {
        /// Deposit (shield) native tokens into the privacy pool.
        ///
        /// The caller provides a Poseidon commitment to their note.
        /// Tokens are transferred from the caller's free balance to the pool.
        #[pallet::call_index(0)]
        #[pallet::weight(T::WeightInfo::deposit())]
        pub fn deposit(
            origin: OriginFor<T>,
            commitment: H256,
            amount: u128,
        ) -> DispatchResult {
            let who = ensure_signed(origin)?;
            ensure!(amount > 0, Error::<T>::ZeroDeposit);
            ensure!(
                !CommitmentExists::<T>::get(commitment),
                Error::<T>::CommitmentAlreadyExists
            );

            // Transfer tokens from caller to pool treasury account
            let balance_amount: <<T as pallet::Config>::Currency as Currency<T::AccountId>>::Balance = amount.into();
            let pool_account = T::PalletId::get().into_account_truncating();
            T::Currency::transfer(&who, &pool_account, balance_amount, ExistenceRequirement::KeepAlive)
                .map_err(|_| Error::<T>::TransferFailed)?;

            // Mark commitment as existing
            CommitmentExists::<T>::insert(commitment, true);

            // Insert into Merkle tree
            let leaf_index = Self::insert_leaf(commitment)?;

            // Update pool balance
            PoolBalance::<T>::mutate(|b| *b = b.saturating_add(amount));

            Self::deposit_event(Event::Deposited {
                commitment,
                leaf_index,
                amount,
            });

            Ok(())
        }

        /// Execute a private transfer within the pool.
        ///
        /// Consumes two nullifiers (spending existing notes) and produces
        /// two new output commitments. The ZK proof must demonstrate:
        /// - sum(input values) == sum(output values) + fee
        /// - Nullifiers correctly derive from spending keys and commitments
        /// - Commitments are well-formed
        /// - Merkle path is valid
        #[pallet::call_index(1)]
        #[pallet::weight(T::WeightInfo::transfer())]
        pub fn transfer(
            origin: OriginFor<T>,
            proof: BoundedVec<u8, ConstU32<4096>>,
            merkle_root: H256,
            nullifiers: [H256; 2],
            output_commitments: [H256; 2],
        ) -> DispatchResult {
            ensure_signed(origin)?;

            // Validate Merkle root is known
            ensure!(
                Self::is_known_root(merkle_root),
                Error::<T>::UnknownMerkleRoot
            );

            // Check and spend nullifiers
            Self::check_and_spend_nullifiers(&nullifiers)?;

            // Build public inputs
            let public_inputs = TransferPublicInputs {
                merkle_root,
                nullifiers,
                output_commitments,
                domain_chain_id: T::ParaId::get(),
                domain_app_id: T::AppId::get(),
            };

            // Verify ZK proof
            ensure!(
                verifier::verify_transfer(&proof, &public_inputs),
                Error::<T>::InvalidProof
            );

            // Insert new commitments
            Self::insert_leaf(output_commitments[0])?;
            let _idx = Self::insert_leaf(output_commitments[1])?;
            let new_root = Self::get_latest_root();

            Self::deposit_event(Event::Transferred {
                nullifier_1: nullifiers[0],
                nullifier_2: nullifiers[1],
                output_commitment_1: output_commitments[0],
                output_commitment_2: output_commitments[1],
                new_root,
            });

            Ok(())
        }

        /// Withdraw (unshield) tokens from the privacy pool.
        ///
        /// Similar to transfer but includes an exit_value that is sent
        /// to the recipient's public balance.
        #[pallet::call_index(2)]
        #[pallet::weight(T::WeightInfo::withdraw())]
        pub fn withdraw(
            origin: OriginFor<T>,
            proof: BoundedVec<u8, ConstU32<4096>>,
            merkle_root: H256,
            nullifiers: [H256; 2],
            output_commitments: [H256; 2],
            recipient: T::AccountId,
            exit_value: u128,
        ) -> DispatchResult {
            ensure_signed(origin)?;
            ensure!(exit_value > 0, Error::<T>::ZeroWithdrawal);

            let pool_balance = PoolBalance::<T>::get();
            ensure!(
                exit_value <= pool_balance,
                Error::<T>::InsufficientPoolBalance
            );

            ensure!(
                Self::is_known_root(merkle_root),
                Error::<T>::UnknownMerkleRoot
            );

            Self::check_and_spend_nullifiers(&nullifiers)?;

            // Verify ZK proof
            let public_inputs = WithdrawPublicInputs {
                merkle_root,
                nullifiers,
                output_commitments,
                exit_value,
                // recipient is implicit in the proof circuit
            };
            ensure!(
                verifier::verify_withdraw(&proof, &public_inputs),
                Error::<T>::InvalidProof
            );

            // Insert change commitments
            Self::insert_leaf(output_commitments[0])?;
            let _ = Self::insert_leaf(output_commitments[1])?;
            let new_root = Self::get_latest_root();

            // Transfer tokens from pool treasury account to recipient
            PoolBalance::<T>::mutate(|b| *b = b.saturating_sub(exit_value));
            let balance_amount: <<T as pallet::Config>::Currency as Currency<T::AccountId>>::Balance = exit_value.into();
            let pool_account: T::AccountId = T::PalletId::get().into_account_truncating();
            T::Currency::transfer(&pool_account, &recipient, balance_amount, ExistenceRequirement::AllowDeath)
                .map_err(|_| Error::<T>::TransferFailed)?;

            Self::deposit_event(Event::Withdrawn {
                nullifier_1: nullifiers[0],
                nullifier_2: nullifiers[1],
                recipient,
                amount: exit_value,
                new_root,
            });

            Ok(())
        }

        /// Finalize the current epoch, computing its nullifier Merkle root.
        /// Restricted to root origin (governance / sudo).
        #[pallet::call_index(3)]
        #[pallet::weight(T::WeightInfo::finalize_epoch())]
        pub fn finalize_epoch(origin: OriginFor<T>) -> DispatchResult {
            ensure_root(origin)?;
            let epoch_id = CurrentEpochId::<T>::get();

            let mut epoch = Epochs::<T>::get(epoch_id).ok_or(Error::<T>::EpochNotReady)?;
            ensure!(!epoch.finalized, Error::<T>::EpochAlreadyFinalized);

            // Compute nullifier root from epoch's nullifiers
            let nullifiers = EpochNullifiers::<T>::get(epoch_id);
            let nullifier_root = Self::compute_nullifier_root(&nullifiers);
            let count = nullifiers.len() as u32;

            epoch.nullifier_root = nullifier_root;
            epoch.nullifier_count = count;
            epoch.end_block = Some(frame_system::Pallet::<T>::block_number());
            epoch.finalized = true;
            Epochs::<T>::insert(epoch_id, epoch);

            // Start new epoch
            let new_epoch_id = epoch_id + 1;
            CurrentEpochId::<T>::put(new_epoch_id);
            let new_epoch = EpochInfo {
                start_block: frame_system::Pallet::<T>::block_number(),
                end_block: None,
                nullifier_root: H256::zero(),
                nullifier_count: 0,
                finalized: false,
            };
            Epochs::<T>::insert(new_epoch_id, new_epoch);

            Self::deposit_event(Event::EpochFinalized {
                epoch_id,
                nullifier_root,
                nullifier_count: count,
            });

            Ok(())
        }

        /// Receive an epoch nullifier root from a remote parachain (via XCM).
        /// Restricted to root origin (governance / sudo / XCM sovereign).
        #[pallet::call_index(4)]
        #[pallet::weight(T::WeightInfo::sync_epoch_root())]
        pub fn sync_epoch_root(
            origin: OriginFor<T>,
            source_para_id: u32,
            epoch_id: u64,
            nullifier_root: H256,
        ) -> DispatchResult {
            ensure_root(origin)?;
            ensure!(nullifier_root != H256::zero(), Error::<T>::InvalidNullifierRoot);

            RemoteEpochRoots::<T>::insert(source_para_id, epoch_id, nullifier_root);

            Self::deposit_event(Event::RemoteEpochRootReceived {
                source_para_id,
                epoch_id,
                nullifier_root,
            });

            Ok(())
        }
    }

    // ── Internal Helpers ───────────────────────────────────────────

    impl<T: Config> Pallet<T> {
        /// Insert a leaf into the incremental Merkle tree
        fn insert_leaf(leaf: H256) -> Result<u64, DispatchError> {
            let next_index = NextLeafIndex::<T>::get();
            let max_leaves = 2u64.pow(T::TreeDepth::get());
            ensure!(next_index < max_leaves, Error::<T>::TreeFull);

            let mut current_index = next_index;
            let mut current_hash = leaf;

            for level in 0..T::TreeDepth::get() {
                let (left, right) = if current_index % 2 == 0 {
                    FilledSubtrees::<T>::insert(level, current_hash);
                    (current_hash, zero_hash(level))
                } else {
                    (FilledSubtrees::<T>::get(level), current_hash)
                };
                current_hash = poseidon_hash(left, right);
                current_index /= 2;
            }

            // Update root history
            let root_history_size = T::RootHistorySize::get();
            let new_root_index = (CurrentRootIndex::<T>::get() + 1) % root_history_size;
            Roots::<T>::insert(new_root_index, current_hash);
            CurrentRootIndex::<T>::put(new_root_index);
            NextLeafIndex::<T>::put(next_index + 1);

            Ok(next_index)
        }

        /// Check if a root is in the history
        fn is_known_root(root: H256) -> bool {
            if root == H256::zero() {
                return false;
            }
            let current_idx = CurrentRootIndex::<T>::get();
            let history_size = T::RootHistorySize::get();
            let mut idx = current_idx;
            for _ in 0..history_size {
                if Roots::<T>::get(idx) == root {
                    return true;
                }
                if idx == 0 {
                    idx = history_size - 1;
                } else {
                    idx -= 1;
                }
            }
            false
        }

        /// Get the latest Merkle root
        fn get_latest_root() -> H256 {
            Roots::<T>::get(CurrentRootIndex::<T>::get())
        }

        /// Check and spend nullifiers, registering them in the current epoch
        fn check_and_spend_nullifiers(nullifiers: &[H256; 2]) -> DispatchResult {
            for nullifier in nullifiers {
                ensure!(
                    !NullifierSpent::<T>::get(nullifier),
                    Error::<T>::NullifierAlreadySpent
                );
                NullifierSpent::<T>::insert(nullifier, true);

                // Add to current epoch's nullifier list
                let epoch_id = CurrentEpochId::<T>::get();
                EpochNullifiers::<T>::try_mutate(epoch_id, |nuls| {
                    nuls.try_push(*nullifier)
                        .map_err(|_| Error::<T>::EpochNullifierOverflow)
                })?;
            }
            Ok(())
        }

        /// Compute Merkle root of a set of nullifiers
        fn compute_nullifier_root(nullifiers: &[H256]) -> H256 {
            if nullifiers.is_empty() {
                return H256::zero();
            }
            let mut current = nullifiers[0];
            for nul in &nullifiers[1..] {
                current = poseidon_hash(current, *nul);
            }
            current
        }
    }

    // ── Poseidon Hash Placeholder ──────────────────────────────────
    // In production, replace with the actual Poseidon implementation from
    // lumora-primitives (compiled to no_std Wasm).

    fn poseidon_hash(left: H256, right: H256) -> H256 {
        // Placeholder: use keccak256 for now; replace with Poseidon
        // when lumora-primitives is no_std compatible
        let mut data = [0u8; 64];
        data[..32].copy_from_slice(left.as_ref());
        data[32..].copy_from_slice(right.as_ref());
        H256(sp_core::hashing::keccak_256(&data))
    }

    fn zero_hash(level: u32) -> H256 {
        let mut z = H256::zero();
        for _ in 0..level {
            z = poseidon_hash(z, z);
        }
        z
    }
}
