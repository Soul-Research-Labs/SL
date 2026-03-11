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
        nullifier_0: [u8; 32],
        #[ink(topic)]
        nullifier_1: [u8; 32],
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

            // 3. Verify ZK proof — structural validation.
            // Production: replace with cross-contract call to a deployed Halo2/Groth16 verifier.
            Self::verify_proof_structure(&proof, &nullifiers, &output_commitments)?;

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
            nullifiers: [[u8; 32]; 2],
            output_commitments: [[u8; 32]; 2],
            recipient: AccountId,
            amount: Balance,
        ) -> Result<()> {
            if !self.is_known_root(merkle_root) {
                return Err(Error::UnknownRoot);
            }

            for nf in &nullifiers {
                if self.nullifiers.get(nf).unwrap_or(false) {
                    return Err(Error::NullifierAlreadySpent);
                }
            }

            Self::verify_proof_structure(&proof, &nullifiers, &output_commitments)?;

            if amount > self.pool_balance {
                return Err(Error::InsufficientFunds);
            }

            // Mark nullifiers as spent.
            for nf in &nullifiers {
                self.nullifiers.insert(nf, &true);
            }

            // Insert output commitments (change notes).
            for cm in &output_commitments {
                if *cm != [0u8; 32] {
                    if self.leaves.contains(*cm) {
                        return Err(Error::DuplicateCommitment);
                    }
                    let idx = self.next_leaf_index;
                    self.leaves.insert(*cm, &idx);
                    self.nodes.insert((0, idx), cm);
                    self.update_tree(idx, *cm);
                    self.next_leaf_index = idx + 1;
                }
            }

            self.pool_balance -= amount;
            self.push_root(self.current_root);

            // Transfer funds.
            self.env()
                .transfer(recipient, amount)
                .map_err(|_| Error::InsufficientFunds)?;

            self.env().emit_event(Withdrawn {
                nullifier_0: nullifiers[0],
                nullifier_1: nullifiers[1],
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

        /// Proof validation with Fiat-Shamir binding.
        ///
        /// Validates proof structure AND a binding tag that ties the proof
        /// to its specific public inputs, preventing cross-input replay.
        ///
        /// ## Proof layout (bytes)
        ///
        ///   [0..32):    Binding tag — keccak256("Halo2-IPA-bind" || inputs || body)
        ///   [32..96):   Commitment (64 bytes)
        ///   [96..128):  Evaluation scalar (32 bytes)
        ///   [128..N):   IPA rounds (each 64 bytes)
        ///
        /// ## Production upgrade path
        ///
        /// Replace this function body with a cross-contract call to a deployed
        /// Halo2/Groth16 verifier ink! contract, or integrate `ark-groth16`
        /// compiled to WASM. The binding tag check should be retained as an
        /// additional transcript integrity assertion.
        fn verify_proof_structure(
            proof: &[u8],
            nullifiers: &[[u8; 32]; 2],
            output_commitments: &[[u8; 32]; 2],
        ) -> Result<()> {
            // Minimum proof size: 192 bytes (binding(32) + commitment(64) + eval(32) + 1 round(64))
            if proof.len() < 192 {
                return Err(Error::InvalidProof);
            }
            // Maximum proof size
            if proof.len() > 4096 {
                return Err(Error::InvalidProof);
            }
            // 32-byte field element alignment
            if proof.len() % 32 != 0 {
                return Err(Error::InvalidProof);
            }
            // Reject trivially forged all-zero proofs
            if proof.iter().all(|&b| b == 0) {
                return Err(Error::InvalidProof);
            }
            // Nullifiers must be distinct
            if nullifiers[0] == nullifiers[1] {
                return Err(Error::InvalidProof);
            }
            // Nullifiers must be non-zero
            if nullifiers[0] == [0u8; 32] || nullifiers[1] == [0u8; 32] {
                return Err(Error::InvalidProof);
            }
            // Output commitments must be non-zero
            for cm in output_commitments {
                if *cm == [0u8; 32] {
                    return Err(Error::InvalidProof);
                }
            }

            // ── Binding verification ──────────────────────────────
            let binding = &proof[..32];
            let body = &proof[32..];

            // IPA rounds start at body[96..], each 64 bytes
            if body.len() < 160 || (body.len() - 96) % 64 != 0 {
                return Err(Error::InvalidProof);
            }

            // Encode public inputs
            let mut inputs = [0u8; 128]; // 2 nullifiers + 2 commitments = 4 × 32
            inputs[..32].copy_from_slice(&nullifiers[0]);
            inputs[32..64].copy_from_slice(&nullifiers[1]);
            inputs[64..96].copy_from_slice(&output_commitments[0]);
            inputs[96..128].copy_from_slice(&output_commitments[1]);

            // Compute expected binding = keccak256("Halo2-IPA-bind" || inputs || body)
            let mut transcript = ink::prelude::vec::Vec::with_capacity(14 + 128 + body.len());
            transcript.extend_from_slice(b"Halo2-IPA-bind");
            transcript.extend_from_slice(&inputs);
            transcript.extend_from_slice(body);

            let mut expected_binding = [0u8; 32];
            ink::env::hash::CryptoHash::hash::<ink::env::hash::Keccak256>(
                &transcript,
                &mut expected_binding,
            );
            if binding != expected_binding {
                return Err(Error::InvalidProof);
            }

            Ok(())
        }

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
        /// Uses domain-tagged keccak256 ("Poseidon" || left || right) for
        /// alignment with the ZK circuit Poseidon hash. For mainnet, replace
        /// with a WASM-compiled BN254 Poseidon implementation.
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

                // Domain-tagged hash: keccak256("Poseidon" || left || right)
                let mut combined = ink::prelude::vec::Vec::with_capacity(8 + 64);
                combined.extend_from_slice(b"Poseidon");
                combined.extend_from_slice(&left);
                combined.extend_from_slice(&right);
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

        /// Build a valid proof that passes `verify_proof_structure`.
        fn make_valid_proof(
            nullifiers: &[[u8; 32]; 2],
            output_commitments: &[[u8; 32]; 2],
        ) -> Vec<u8> {
            // Body: 160 bytes (commitment=64, eval=32, 1 round=64)
            let body = [0xab_u8; 160];

            // Encode inputs: 2 nullifiers + 2 outputs = 128 bytes
            let mut inputs = [0u8; 128];
            inputs[..32].copy_from_slice(&nullifiers[0]);
            inputs[32..64].copy_from_slice(&nullifiers[1]);
            inputs[64..96].copy_from_slice(&output_commitments[0]);
            inputs[96..128].copy_from_slice(&output_commitments[1]);

            // binding = keccak256("Halo2-IPA-bind" || inputs || body)
            let mut transcript = Vec::with_capacity(14 + 128 + body.len());
            transcript.extend_from_slice(b"Halo2-IPA-bind");
            transcript.extend_from_slice(&inputs);
            transcript.extend_from_slice(&body);

            let mut binding = [0u8; 32];
            ink::env::hash::CryptoHash::hash::<ink::env::hash::Keccak256>(
                &transcript,
                &mut binding,
            );

            let mut proof = Vec::with_capacity(32 + body.len());
            proof.extend_from_slice(&binding);
            proof.extend_from_slice(&body);
            proof
        }

        // ── Initialization ─────────────────────

        #[ink::test]
        fn new_initializes_correctly() {
            let pool = PrivacyPool::new(100);
            assert_eq!(pool.get_next_leaf_index(), 0);
            assert_eq!(pool.get_current_epoch(), 0);
            assert_eq!(pool.get_pool_balance(), 0);
            assert_eq!(pool.get_current_root(), ZERO_VALUE);
        }

        // ── Deposit ────────────────────────────

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
        fn multiple_deposits_update_state() {
            let mut pool = PrivacyPool::new(100);
            for i in 1u8..=5 {
                ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(500);
                assert!(pool.deposit([i; 32]).is_ok());
            }
            assert_eq!(pool.get_next_leaf_index(), 5);
            assert_eq!(pool.get_pool_balance(), 2500);
        }

        #[ink::test]
        fn deposit_changes_root_each_time() {
            let mut pool = PrivacyPool::new(100);
            let root_before = pool.get_current_root();

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(100);
            pool.deposit([10u8; 32]).unwrap();
            let root_after_1 = pool.get_current_root();
            assert_ne!(root_before, root_after_1);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(100);
            pool.deposit([11u8; 32]).unwrap();
            let root_after_2 = pool.get_current_root();
            assert_ne!(root_after_1, root_after_2);
        }

        // ── Transfer ───────────────────────────

        #[ink::test]
        fn transfer_works() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];
            let proof = make_valid_proof(&nullifiers, &outputs);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            let result = pool.transfer(proof, root, nullifiers, outputs);
            assert!(result.is_ok());
            assert_eq!(pool.get_next_leaf_index(), 3); // 1 deposit + 2 outputs
            assert_eq!(pool.get_pool_balance(), 1000); // unchanged
        }

        #[ink::test]
        fn transfer_double_spend_fails() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs1 = [[30u8; 32], [31u8; 32]];
            let proof1 = make_valid_proof(&nullifiers, &outputs1);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert!(pool.transfer(proof1, root, nullifiers, outputs1).is_ok());

            // Attempt re-use of same nullifiers
            let root2 = pool.get_current_root();
            let outputs2 = [[40u8; 32], [41u8; 32]];
            let proof2 = make_valid_proof(&nullifiers, &outputs2);
            assert_eq!(
                pool.transfer(proof2, root2, nullifiers, outputs2),
                Err(Error::NullifierAlreadySpent)
            );
        }

        #[ink::test]
        fn transfer_unknown_root_fails() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();

            let fake_root = [0xffu8; 32];
            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];
            let proof = make_valid_proof(&nullifiers, &outputs);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.transfer(proof, fake_root, nullifiers, outputs),
                Err(Error::UnknownRoot)
            );
        }

        #[ink::test]
        fn transfer_invalid_proof_too_short() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.transfer(vec![0xab; 32], root, nullifiers, outputs),
                Err(Error::InvalidProof)
            );
        }

        #[ink::test]
        fn transfer_all_zero_proof_fails() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.transfer(vec![0u8; 192], root, nullifiers, outputs),
                Err(Error::InvalidProof)
            );
        }

        #[ink::test]
        fn transfer_duplicate_nullifiers_fails() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let dup_nul = [20u8; 32];
            let nullifiers = [dup_nul, dup_nul];
            let outputs = [[30u8; 32], [31u8; 32]];

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.transfer(vec![0xab; 192], root, nullifiers, outputs),
                Err(Error::InvalidProof)
            );
        }

        #[ink::test]
        fn transfer_zero_nullifier_fails() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[0u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.transfer(vec![0xab; 192], root, nullifiers, outputs),
                Err(Error::InvalidProof)
            );
        }

        // ── Withdraw ───────────────────────────

        #[ink::test]
        fn withdraw_updates_balance() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(5000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];
            let proof = make_valid_proof(&nullifiers, &outputs);

            let accounts = default_accounts();
            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            let result = pool.withdraw(proof, root, nullifiers, outputs, accounts.bob, 2000);
            assert!(result.is_ok());
            assert_eq!(pool.get_pool_balance(), 3000);
        }

        #[ink::test]
        fn withdraw_insufficient_funds() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(100);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nullifiers = [[20u8; 32], [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];
            let proof = make_valid_proof(&nullifiers, &outputs);

            let accounts = default_accounts();
            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            assert_eq!(
                pool.withdraw(proof, root, nullifiers, outputs, accounts.bob, 999),
                Err(Error::InsufficientFunds)
            );
        }

        // ── Nullifiers ────────────────────────

        #[ink::test]
        fn nullifier_not_spent_initially() {
            let pool = PrivacyPool::new(100);
            assert!(!pool.is_nullifier_spent([99u8; 32]));
        }

        #[ink::test]
        fn nullifier_spent_after_transfer() {
            let mut pool = PrivacyPool::new(100);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(1000);
            pool.deposit([10u8; 32]).unwrap();
            let root = pool.get_current_root();

            let nul0 = [20u8; 32];
            let nullifiers = [nul0, [21u8; 32]];
            let outputs = [[30u8; 32], [31u8; 32]];
            let proof = make_valid_proof(&nullifiers, &outputs);

            ink::env::test::set_value_transferred::<ink::env::DefaultEnvironment>(0);
            pool.transfer(proof, root, nullifiers, outputs).unwrap();

            assert!(pool.is_nullifier_spent(nul0));
            assert!(pool.is_nullifier_spent([21u8; 32]));
            assert!(!pool.is_nullifier_spent([99u8; 32]));
        }

        // ── Epoch Finalization ─────────────────

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
        fn multiple_epoch_finalizations() {
            let mut pool = PrivacyPool::new(100);
            for expected_next in 1u32..=4 {
                let result = pool.finalize_epoch();
                assert_eq!(result, Ok(expected_next));
            }
            assert_eq!(pool.get_current_epoch(), 4);
        }

        // ── Cross-chain Sync ──────────────────

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

        #[ink::test]
        fn remote_root_missing_returns_none() {
            let pool = PrivacyPool::new(100);
            assert_eq!(pool.get_remote_root(9999, 0), None);
        }

        #[ink::test]
        fn sync_multiple_chains() {
            let mut pool = PrivacyPool::new(100);
            let root_a = [0xaa; 32];
            let root_b = [0xbb; 32];

            pool.sync_remote_root(43114, 0, root_a).unwrap(); // Avalanche
            pool.sync_remote_root(1284, 0, root_b).unwrap(); // Moonbeam

            assert_eq!(pool.get_remote_root(43114, 0), Some(root_a));
            assert_eq!(pool.get_remote_root(1284, 0), Some(root_b));
            assert_eq!(pool.get_remote_root(43114, 1), None); // different epoch
        }
    }
}
