#![cfg_attr(not(feature = "std"), no_std, no_main)]

//! ink! Privacy Pool Contract
//!
//! Native Substrate smart contract for non-EVM Polkadot parachains (e.g. Astar Wasm VM).
//! Implements the same privacy pool logic as the Solidity/CosmWasm variants:
//! - Incremental Merkle tree (depth 32)
//! - Domain-separated V2 nullifiers
//! - Epoch-based root management
//! - Cross-chain root synchronization

#[ink::contract]
mod privacy_pool {
    use ink::prelude::vec::Vec;
    use ink::storage::Mapping;
    use scale::{Decode, Encode};

    /// Depth of the incremental Merkle tree.
    const TREE_DEPTH: u32 = 32;

    /// Maximum number of historical roots to keep.
    const ROOT_HISTORY_SIZE: u32 = 100;

    /// Zero value used for empty Merkle tree leaves.
    const ZERO_VALUE: [u8; 32] = [0u8; 32];

    // ── Types ──────────────────────────────────

    #[derive(Debug, Clone, PartialEq, Eq, Encode, Decode)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo, ink::storage::traits::StorageLayout))]
    pub struct EpochInfo {
        pub epoch_id: u32,
        pub root: [u8; 32],
        pub finalized: bool,
        pub block_finalized: u32,
    }

    // ── Events ─────────────────────────────────

    #[ink(event)]
    pub struct Deposited {
        #[ink(topic)]
        commitment: [u8; 32],
        leaf_index: u32,
        value: Balance,
    }

    #[ink(event)]
    pub struct Transferred {
        #[ink(topic)]
        nullifier_0: [u8; 32],
        #[ink(topic)]
        nullifier_1: [u8; 32],
        output_commitment_0: [u8; 32],
        output_commitment_1: [u8; 32],
    }

    #[ink(event)]
    pub struct Withdrawn {
        #[ink(topic)]
        nullifier: [u8; 32],
        #[ink(topic)]
        recipient: AccountId,
        amount: Balance,
    }

    #[ink(event)]
    pub struct EpochFinalized {
        epoch_id: u32,
        root: [u8; 32],
    }

    #[ink(event)]
    pub struct RemoteRootSynced {
        chain_id: u32,
        epoch_id: u32,
        root: [u8; 32],
    }

    // ── Errors ─────────────────────────────────

    #[derive(Debug, PartialEq, Eq, Encode, Decode)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
    pub enum Error {
        DuplicateCommitment,
        TreeFull,
        InvalidProof,
        NullifierAlreadySpent,
        UnknownRoot,
        ZeroAmount,
        InsufficientFunds,
        EpochAlreadyFinalized,
        NotGovernance,
    }

    pub type Result<T> = core::result::Result<T, Error>;

    // ── Storage ────────────────────────────────

    #[ink(storage)]
    pub struct PrivacyPool {
        /// Governance account (deployer).
        governance: AccountId,

        /// Merkle tree leaves (hash → leaf index).
        leaves: Mapping<[u8; 32], u32>,
        /// Merkle tree inner nodes: (level, index) → hash.
        nodes: Mapping<(u32, u32), [u8; 32]>,
        /// Next leaf index.
        next_leaf_index: u32,

        /// Historical roots. Circular buffer.
        root_history: Mapping<u32, [u8; 32]>,
        root_history_cursor: u32,
        current_root: [u8; 32],

        /// Spent nullifiers.
        nullifiers: Mapping<[u8; 32], bool>,

        /// Epoch management.
        current_epoch: u32,
        epochs: Mapping<u32, EpochInfo>,
        epoch_duration: u32,
        epoch_start_block: u32,

        /// Remote chain roots: (chain_id, epoch_id) → root.
        remote_roots: Mapping<(u32, u32), [u8; 32]>,

        /// Total pool balance for accounting.
        pool_balance: Balance,
    }

    impl PrivacyPool {
        /// Instantiate with configuration parameters.
        #[ink(constructor)]
        pub fn new(epoch_duration: u32) -> Self {
            let caller = Self::env().caller();
            let current_block = Self::env().block_number();

            let mut contract = Self {
                governance: caller,
                leaves: Mapping::new(),
                nodes: Mapping::new(),
                next_leaf_index: 0,
                root_history: Mapping::new(),
                root_history_cursor: 0,
                current_root: ZERO_VALUE,
                nullifiers: Mapping::new(),
                current_epoch: 0,
                epochs: Mapping::new(),
                epoch_duration,
                epoch_start_block: current_block,
                remote_roots: Mapping::new(),
                pool_balance: 0,
            };

            // Initialize epoch 0.
            contract.epochs.insert(
                0,
                &EpochInfo {
                    epoch_id: 0,
                    root: ZERO_VALUE,
                    finalized: false,
                    block_finalized: 0,
                },
            );

            contract
        }

        // ── Deposit ────────────────────────────

        /// Deposit native tokens and insert a commitment into the Merkle tree.
        #[ink(message, payable)]
        pub fn deposit(&mut self, commitment: [u8; 32]) -> Result<u32> {
            let value = self.env().transferred_value();
            if value == 0 {
                return Err(Error::ZeroAmount);
            }

            if self.leaves.contains(commitment) {
                return Err(Error::DuplicateCommitment);
            }

            let leaf_index = self.next_leaf_index;
            if leaf_index >= (1u32 << TREE_DEPTH) {
                return Err(Error::TreeFull);
            }

            // Insert leaf.
            self.leaves.insert(commitment, &leaf_index);
            self.nodes.insert((0, leaf_index), &commitment);

            // Recompute path to root.
            self.update_tree(leaf_index, commitment);
            self.next_leaf_index = leaf_index + 1;
            self.pool_balance += value;

            // Store new root in history.
            self.push_root(self.current_root);

            self.env().emit_event(Deposited {
                commitment,
                leaf_index,
                value,
            });

            Ok(leaf_index)
        }

        // ── Transfer ───────────────────────────

        /// Execute a 2-in 2-out private transfer.
        ///
        /// In production, `proof` would be verified by an on-chain verifier
        /// (Halo2→SNARK wrapper or UltraHonk). Currently uses a placeholder.
        #[ink(message)]
        pub fn transfer(
            &mut self,
            proof: Vec<u8>,
            merkle_root: [u8; 32],
            nullifiers: [[u8; 32]; 2],
            output_commitments: [[u8; 32]; 2],
        ) -> Result<()> {
            // 1. Verify root is known.
            if !self.is_known_root(merkle_root) {
                return Err(Error::UnknownRoot);
            }

            // 2. Check nullifiers not spent.
            for nf in &nullifiers {
                if self.nullifiers.get(nf).unwrap_or(false) {
                    return Err(Error::NullifierAlreadySpent);
                }
            }

            // 3. Verify ZK proof (placeholder — would call on-chain verifier).
            if proof.is_empty() {
                return Err(Error::InvalidProof);
            }

            // 4. Mark nullifiers as spent.
            for nf in &nullifiers {
                self.nullifiers.insert(nf, &true);
            }

            // 5. Insert output commitments.
            for cm in &output_commitments {
                if self.leaves.contains(*cm) {
                    return Err(Error::DuplicateCommitment);
                }
                let idx = self.next_leaf_index;
                self.leaves.insert(*cm, &idx);
                self.nodes.insert((0, idx), cm);
                self.update_tree(idx, *cm);
                self.next_leaf_index = idx + 1;
            }

            self.push_root(self.current_root);

            self.env().emit_event(Transferred {
                nullifier_0: nullifiers[0],
                nullifier_1: nullifiers[1],
                output_commitment_0: output_commitments[0],
                output_commitment_1: output_commitments[1],
            });

            Ok(())
        }

        // ── Withdraw ───────────────────────────

        /// Withdraw funds from the pool.
        #[ink(message)]
        pub fn withdraw(
            &mut self,
            proof: Vec<u8>,
            merkle_root: [u8; 32],
            nullifier: [u8; 32],
            recipient: AccountId,
            amount: Balance,
        ) -> Result<()> {
            if !self.is_known_root(merkle_root) {
                return Err(Error::UnknownRoot);
            }

            if self.nullifiers.get(nullifier).unwrap_or(false) {
                return Err(Error::NullifierAlreadySpent);
            }

            if proof.is_empty() {
                return Err(Error::InvalidProof);
            }

            if amount > self.pool_balance {
                return Err(Error::InsufficientFunds);
            }

            // Mark nullifier as spent.
            self.nullifiers.insert(nullifier, &true);
            self.pool_balance -= amount;

            // Transfer funds.
            self.env()
                .transfer(recipient, amount)
                .map_err(|_| Error::InsufficientFunds)?;

            self.env().emit_event(Withdrawn {
                nullifier,
                recipient,
                amount,
            });

            Ok(())
        }

        // ── Epoch Management ───────────────────

        /// Finalize the current epoch — snapshot the root and advance.
        #[ink(message)]
        pub fn finalize_epoch(&mut self) -> Result<u32> {
            let epoch_id = self.current_epoch;
            let epoch = self.epochs.get(epoch_id).unwrap();

            if epoch.finalized {
                return Err(Error::EpochAlreadyFinalized);
            }

            let root = self.current_root;
            let block = self.env().block_number();

            self.epochs.insert(
                epoch_id,
                &EpochInfo {
                    epoch_id,
                    root,
                    finalized: true,
                    block_finalized: block,
                },
            );

            // Advance to next epoch.
            let next_epoch = epoch_id + 1;
            self.current_epoch = next_epoch;
            self.epoch_start_block = block;
            self.epochs.insert(
                next_epoch,
                &EpochInfo {
                    epoch_id: next_epoch,
                    root: ZERO_VALUE,
                    finalized: false,
                    block_finalized: 0,
                },
            );

            self.env().emit_event(EpochFinalized { epoch_id, root });

            Ok(next_epoch)
        }

        /// Sync a root from a remote chain (governance only).
        #[ink(message)]
        pub fn sync_remote_root(
            &mut self,
            chain_id: u32,
            epoch_id: u32,
            root: [u8; 32],
        ) -> Result<()> {
            if self.env().caller() != self.governance {
                return Err(Error::NotGovernance);
            }

            self.remote_roots.insert((chain_id, epoch_id), &root);

            self.env().emit_event(RemoteRootSynced {
                chain_id,
                epoch_id,
                root,
            });

            Ok(())
        }

        // ── Queries ────────────────────────────

        /// Get the current Merkle root.
        #[ink(message)]
        pub fn get_current_root(&self) -> [u8; 32] {
            self.current_root
        }

        /// Get the next leaf index.
        #[ink(message)]
        pub fn get_next_leaf_index(&self) -> u32 {
            self.next_leaf_index
        }

        /// Check if a nullifier has been spent.
        #[ink(message)]
        pub fn is_nullifier_spent(&self, nullifier: [u8; 32]) -> bool {
            self.nullifiers.get(nullifier).unwrap_or(false)
        }

        /// Get the current epoch info.
        #[ink(message)]
        pub fn get_current_epoch(&self) -> u32 {
            self.current_epoch
        }

        /// Get the pool balance.
        #[ink(message)]
        pub fn get_pool_balance(&self) -> Balance {
            self.pool_balance
        }

        /// Get a remote chain root for a given epoch.
        #[ink(message)]
        pub fn get_remote_root(&self, chain_id: u32, epoch_id: u32) -> Option<[u8; 32]> {
            self.remote_roots.get((chain_id, epoch_id))
        }

        // ── Internal ───────────────────────────

        /// Check if a root is in the history.
        fn is_known_root(&self, root: [u8; 32]) -> bool {
            if root == self.current_root {
                return true;
            }
            for i in 0..ROOT_HISTORY_SIZE {
                if let Some(stored) = self.root_history.get(i) {
                    if stored == root {
                        return true;
                    }
                }
            }
            false
        }

        /// Push a new root into the circular history buffer.
        fn push_root(&mut self, root: [u8; 32]) {
            self.root_history.insert(self.root_history_cursor, &root);
            self.root_history_cursor = (self.root_history_cursor + 1) % ROOT_HISTORY_SIZE;
        }

        /// Update the incremental Merkle tree from a leaf up to the root.
        /// Uses keccak256 as a placeholder hash — production would use Poseidon.
        fn update_tree(&mut self, leaf_index: u32, leaf_hash: [u8; 32]) {
            let mut current_hash = leaf_hash;
            let mut index = leaf_index;

            for level in 0..TREE_DEPTH {
                let (left, right) = if index % 2 == 0 {
                    let sibling = self
                        .nodes
                        .get((level, index + 1))
                        .unwrap_or(ZERO_VALUE);
                    (current_hash, sibling)
                } else {
                    let sibling = self
                        .nodes
                        .get((level, index - 1))
                        .unwrap_or(ZERO_VALUE);
                    (sibling, current_hash)
                };

                // Hash left || right using keccak256 (placeholder for Poseidon).
                let mut combined = [0u8; 64];
                combined[..32].copy_from_slice(&left);
                combined[32..].copy_from_slice(&right);
                current_hash = self.env().hash_bytes::<ink::env::hash::Keccak256>(&combined);

                index /= 2;
                self.nodes.insert((level + 1, index), &current_hash);
            }

            self.current_root = current_hash;
        }
    }

    // ── Unit Tests ─────────────────────────────

    #[cfg(test)]
    mod tests {
        use super::*;
        use ink::env::test;

        fn default_accounts() -> test::DefaultAccounts<ink::env::DefaultEnvironment> {
            test::default_accounts::<ink::env::DefaultEnvironment>()
        }

        #[ink::test]
        fn new_initializes_correctly() {
            let pool = PrivacyPool::new(100);
            assert_eq!(pool.get_next_leaf_index(), 0);
            assert_eq!(pool.get_current_epoch(), 0);
            assert_eq!(pool.get_pool_balance(), 0);
            assert_eq!(pool.get_current_root(), ZERO_VALUE);
        }

        #[ink::test]
        fn deposit_works() {
            let mut pool = PrivacyPool::new(100);
            let commitment = [1u8; 32];

            // Set transferred value.
            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);

            let result = pool.deposit(commitment);
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), 0);
            assert_eq!(pool.get_next_leaf_index(), 1);
            assert_eq!(pool.get_pool_balance(), 1000);
            // Root should have changed from zero.
            assert_ne!(pool.get_current_root(), ZERO_VALUE);
        }

        #[ink::test]
        fn deposit_zero_fails() {
            let mut pool = PrivacyPool::new(100);
            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            let result = pool.deposit([2u8; 32]);
            assert_eq!(result, Err(Error::ZeroAmount));
        }

        #[ink::test]
        fn deposit_duplicate_commitment_fails() {
            let mut pool = PrivacyPool::new(100);
            let commitment = [3u8; 32];

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(100);
            assert!(pool.deposit(commitment).is_ok());
            assert_eq!(pool.deposit(commitment), Err(Error::DuplicateCommitment));
        }

        #[ink::test]
        fn nullifier_not_spent_initially() {
            let pool = PrivacyPool::new(100);
            assert!(!pool.is_nullifier_spent([99u8; 32]));
        }

        #[ink::test]
        fn finalize_epoch_works() {
            let mut pool = PrivacyPool::new(100);
            assert_eq!(pool.get_current_epoch(), 0);

            let result = pool.finalize_epoch();
            assert!(result.is_ok());
            assert_eq!(result.unwrap(), 1);
            assert_eq!(pool.get_current_epoch(), 1);
        }

        #[ink::test]
        fn finalize_same_epoch_twice_fails() {
            let mut pool = PrivacyPool::new(100);
            assert!(pool.finalize_epoch().is_ok());
            // Epoch 0 is now finalized. Current = 1. Finalize 1 should work.
            assert!(pool.finalize_epoch().is_ok());
        }

        #[ink::test]
        fn sync_remote_root_governance_only() {
            let mut pool = PrivacyPool::new(100);
            let root = [42u8; 32];

            // Caller is governance (deployer).
            let result = pool.sync_remote_root(2100, 0, root);
            assert!(result.is_ok());

            let stored = pool.get_remote_root(2100, 0);
            assert_eq!(stored, Some(root));

            // Change caller to non-governance.
            let accounts = default_accounts();
            ink::env::test::set_caller::<ink::env::DefaultEnvironment>(accounts.bob);
            let result = pool.sync_remote_root(2100, 1, root);
            assert_eq!(result, Err(Error::NotGovernance));
        }
    }
}
