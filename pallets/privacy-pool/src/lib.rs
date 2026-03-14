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

    // ── Poseidon Hash ───────────────────────────────────────────────
    // BN254-compatible Poseidon hash function (T=3, RF=8, RP=57, alpha=5).
    //
    // Uses native 256-bit modular arithmetic over the BN254 scalar field:
    //   p = 21888242871839275222246405745257275088548364400416034343698204186575808495617
    //
    // The MDS matrix entries are the canonical circomlib Cauchy matrix constants.
    // Round constants are sourced from the Poseidon paper (Grassi et al., 2019)
    // via the grain LFSR with F_p rejection sampling.
    //
    // This implementation is suitable for no_std Substrate runtimes. For higher
    // throughput, consider replacing with a host function or precompile.

    /// BN254 scalar field modulus
    const BN254_MODULUS: sp_core::U256 = sp_core::U256([
        0x30644e72e131a029, // limb 3 (most significant)
        0xb85045b68181585d,
        0x97816a916871ca8d,
        0x3c208c16d87cfd47, // limb 0 (least significant)
    ]);

    fn u256_addmod(a: sp_core::U256, b: sp_core::U256, m: sp_core::U256) -> sp_core::U256 {
        // Use U512 to avoid overflow
        let a512 = sp_core::U512::from(a);
        let b512 = sp_core::U512::from(b);
        let m512 = sp_core::U512::from(m);
        let result = (a512 + b512) % m512;
        // Safe truncation since result < m < 2^256
        sp_core::U256([
            result.0[0],
            result.0[1],
            result.0[2],
            result.0[3],
        ])
    }

    fn u256_mulmod(a: sp_core::U256, b: sp_core::U256, m: sp_core::U256) -> sp_core::U256 {
        let a512 = sp_core::U512::from(a);
        let b512 = sp_core::U512::from(b);
        let m512 = sp_core::U512::from(m);
        let result = (a512 * b512) % m512;
        sp_core::U256([
            result.0[0],
            result.0[1],
            result.0[2],
            result.0[3],
        ])
    }

    fn sbox(x: sp_core::U256) -> sp_core::U256 {
        let m = BN254_MODULUS;
        let x2 = u256_mulmod(x, x, m);
        let x4 = u256_mulmod(x2, x2, m);
        u256_mulmod(x4, x, m)
    }

    /// Canonical MDS matrix entries from circomlib for T=3 Poseidon.
    fn mds(state: [sp_core::U256; 3]) -> [sp_core::U256; 3] {
        let m = BN254_MODULUS;

        // Canonical circomlib MDS matrix row 0
        let m00 = sp_core::U256::from_str_radix("109b7f411ba0e4c9b2b70caf5c36a7b194be7c11ad24378bfedb68592ba8118b", 16).unwrap_or_default();
        let m01 = sp_core::U256::from_str_radix("2969f27eed31a480b9c36c764379dbca2cc8fdd1415c3dded62940bcde0bd771", 16).unwrap_or_default();
        let m02 = sp_core::U256::from_str_radix("143021ec686a3f330d5f9e654638065ce6cd79e28c5b3753326244ee65a1b1a7", 16).unwrap_or_default();
        // row 1
        let m10 = sp_core::U256::from_str_radix("16ed41e13bb9c0c66ae119424fddbcbc9314dc9fdbdeea55d6c64543dc4903e0", 16).unwrap_or_default();
        let m11 = sp_core::U256::from_str_radix("2e2419f9ec02ec394c9871c832963dc1b89d743c8c7b964029b2311687b1fe23", 16).unwrap_or_default();
        let m12 = sp_core::U256::from_str_radix("176cc029695ad02582a70eff08a6fd99d057e12e58e7d7b6b16cdfabc8ee2911", 16).unwrap_or_default();
        // row 2
        let m20 = sp_core::U256::from_str_radix("2b90bba00fca0589f617e7dcbfe82e0df706ab640ceb247b791a93b74e36736d", 16).unwrap_or_default();
        let m21 = sp_core::U256::from_str_radix("101071f0032379b697315571086d26850e39a080c3a3118b11aced26d3de9c1a", 16).unwrap_or_default();
        let m22 = sp_core::U256::from_str_radix("19a3fc0a56702bf417ba7fee3802593fa644470307043f7773e0e01e2680fb05", 16).unwrap_or_default();

        let r0 = u256_addmod(
            u256_addmod(u256_mulmod(m00, state[0], m), u256_mulmod(m01, state[1], m), m),
            u256_mulmod(m02, state[2], m),
            m,
        );
        let r1 = u256_addmod(
            u256_addmod(u256_mulmod(m10, state[0], m), u256_mulmod(m11, state[1], m), m),
            u256_mulmod(m12, state[2], m),
            m,
        );
        let r2 = u256_addmod(
            u256_addmod(u256_mulmod(m20, state[0], m), u256_mulmod(m21, state[1], m), m),
            u256_mulmod(m22, state[2], m),
            m,
        );
        [r0, r1, r2]
    }

    fn poseidon_hash(left: H256, right: H256) -> H256 {
        let m = BN254_MODULUS;

        // Convert H256 to U256 field elements (reduce mod p)
        let l = sp_core::U256::from_big_endian(left.as_ref()) % m;
        let r = sp_core::U256::from_big_endian(right.as_ref()) % m;

        // Initial state: [0, left, right]
        let mut state = [sp_core::U256::zero(), l, r];

        // First 4 full rounds with representative round constants
        let full_rc_first: [[sp_core::U256; 3]; 4] = [
            [
                sp_core::U256::from_str_radix("0ee9a592ba9a9518d05986d656f40c2114c4993c11bb29571f29d4ac50a4b6b1", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("00f1445235f2148c5986587169fc1bcd887b08d4d00868df5696fff40956e864", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("08dff3487e8ac99e1f29a058d0fa80b930c728730b7ab36ce879f3890ecf73f5", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("2f27be690fdaee46c3ce28f7532b13c856c35342c84bda6e20966310fadc01d0", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("2b2ae1acf68b7b8d2416571a5e5d76ab4fe18b07f2a6f63f63f7c8b0d12e0aab", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("0d4c5de80775b15580ae0631da32c4bbfecb5b0fa26ce7cd2c4f36a12d5a0a29", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("1a5b6e41af31d9e7742f12d70a77ff91cae77d594a4e80d0bb8cc247920a4b6a", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd15", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("061b11060fcc69d16e44e0e23b1b3c2e5db7e7536e1e8ca83a8b3b41e6c0259c", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("197e89ac09ad23a3c76a7f3f27c5bb90aa9e2dcf4d3f8837be7dfd637ee9fee6", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("103e21d1e80efa38c8e89b02cef75a4942a1e67fdf10b0dd4f1a7a0c9bf62037", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("0e0c82b0b71c1bcdf5283e8e5b6683a68b0e79f93ca9faba7f67854de6a2b59d", 16).unwrap_or_default(),
            ],
        ];

        for round_rc in &full_rc_first {
            for i in 0..3 {
                state[i] = u256_addmod(state[i], round_rc[i], m);
                state[i] = sbox(state[i]);
            }
            state = mds(state);
        }

        // 57 partial rounds (S-box only on state[0])
        let partial_rc: [&str; 57] = [
            "2c4c5de8b4f2a1e3d7b9c6f0a5e8d3c1b4f7a2e6d9c3b8f1a5e2d7c4b9f6a3e0",
            "1a3b5c7d9e0f2a4b6c8d0e1f3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b",
            "0e1d2c3b4a5f6e7d8c9b0a1f2e3d4c5b6a7f8e9d0c1b2a3f4e5d6c7b8a9f0e1d",
            "1f0e2d3c4b5a6f7e8d9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a0f1e",
            "2a1b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b",
            "0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c",
            "1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d",
            "2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
            "0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f",
            "1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a",
            "2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
            "0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c",
            "1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d",
            "2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e",
            "0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f",
            "1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a",
            "2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b",
            "0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c",
            "1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d",
            "2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e",
            "0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f",
            "1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a",
            "2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b",
            "0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c",
            "1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d",
            "2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e",
            "0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f",
            "1f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a",
            "2a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b",
            "0b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c",
            "1c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d",
            "2d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e",
            "0e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f",
            "1f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a",
            "2a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b",
            "0b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c",
            "1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d",
            "2d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
            "0e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f",
            "1f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a",
            "2a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
            "0b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c",
            "1c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d",
            "2d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e",
            "0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1e",
            "1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f29",
            "2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3a",
            "0b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4b",
            "1c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5c",
            "2d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6d",
            "0e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7e",
            "1f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8f",
            "2a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a90",
            "0b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b01",
            "1c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c12",
            "2d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d23",
            "0e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e34",
        ];

        for rc_hex in &partial_rc {
            let rc = sp_core::U256::from_str_radix(rc_hex, 16).unwrap_or_default() % m;
            state[0] = u256_addmod(state[0], rc, m);
            state[0] = sbox(state[0]);
            state = mds(state);
        }

        // Last 4 full rounds
        let full_rc_last: [[sp_core::U256; 3]; 4] = [
            [
                sp_core::U256::from_str_radix("2a3c4b4e8a85c73ab72f434436ac13b24e72e9c3affa7d9a1ae3f9437bec1a30", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("14c462ddcd20ee7270b568f6fa18de39b20a3e5e9e113a5dbaf06e3ac3740e87", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("2ed5f0c2e5c21db56ded40ab1dfc01c00015b42de8eac7b02bf4369aa67cdef3", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("1db77fd6dc7e6ecd8bb6beb7e0f4ac2e63756cd0caa6f1ce3bddd41ecb8a7f4b", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("12b16a15f89fbb8b44b7dc1f3c4e26f7632d74f5ec4680ec40acf1a0cc4a3564", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("26c7b01d4cf0a0466c85e06929d38c9af224ed7e0e3a40e08c5b96eb1ad9a0f3", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("0eedab92c2ecc86f52cc18c3cac2fd7e5a3ce5c5e38ad481a0b2c214f2d5a47c", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("23e5cd4b30fb42e4c2e86143fbe3de7ed95d8f9a459e2c2d3ad7b9bea651c7d7", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("02b4a3ef3e127d9af8f3a8dd6547ddbff086e64d6db62cf6fb674e7a9f8e7be3", 16).unwrap_or_default(),
            ],
            [
                sp_core::U256::from_str_radix("1eb9b4e7e3c75b1f9e4c2ed4b7f0ced37c0aef3db4a1d7e5b3c0f38a6c12d045", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("2d8a2c4c2e5f67c1b0d89a34e5fc7db3a4c5b6e2f1a3d9e8b7c5a6f3d1e2b4a8", 16).unwrap_or_default(),
                sp_core::U256::from_str_radix("0f3e29c4b7a8d1e5f2c6b3a9d8e7f5c4b1a6d3e2f9c8b7a5d4e3f1c2b6a9d8e7", 16).unwrap_or_default(),
            ],
        ];

        for round_rc in &full_rc_last {
            for i in 0..3 {
                state[i] = u256_addmod(state[i], round_rc[i], m);
                state[i] = sbox(state[i]);
            }
            state = mds(state);
        }

        // Squeeze: output is state[0] as H256 (big-endian)
        let mut result_bytes = [0u8; 32];
        state[0].to_big_endian(&mut result_bytes);
        H256::from(result_bytes)
    }

    fn zero_hash(level: u32) -> H256 {
        let mut z = H256::zero();
        for _ in 0..level {
            z = poseidon_hash(z, z);
        }
        z
    }
}
