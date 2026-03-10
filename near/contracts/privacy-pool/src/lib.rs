//! # NEAR Privacy Pool Contract
//!
//! A NEAR smart contract implementing a ZK privacy pool for the Aurora/NEAR
//! ecosystem. Supports cross-chain epoch sync with the Aurora Rainbow Bridge
//! adapter.
//!
//! ## Architecture
//!
//! - Deposits: Attach NEAR tokens to the deposit call with a Poseidon commitment
//! - Transfers: Submit ZK proof + nullifiers + new commitments
//! - Withdrawals: Submit ZK proof, receive NEAR tokens to specified account
//! - Epoch Sync: Receive epoch nullifier roots from Aurora (via Rainbow Bridge)
//!
//! ## Storage Design
//!
//! Uses NEAR's trie-based storage with prefix keys:
//! - `t:` — Merkle tree subtrees
//! - `r:` — Root history
//! - `n:` — Spent nullifiers
//! - `c:` — Commitment existence
//! - `e:` — Epoch data
//! - `en:` — Epoch nullifiers

use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::collections::{LookupMap, UnorderedMap, Vector};
use near_sdk::json_types::U128;
use near_sdk::{env, near_bindgen, AccountId, NearToken, PanicOnDefault, Promise};
use serde::{Deserialize, Serialize};

// ── Constants ──────────────────────────────────────────

const TREE_DEPTH: u32 = 32;
const ROOT_HISTORY_SIZE: u32 = 100;
const MAX_NULLIFIERS_PER_EPOCH: usize = 10_000;
const ZERO_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

// ── Types ──────────────────────────────────────────────

#[derive(BorshDeserialize, BorshSerialize, Serialize, Deserialize, Clone, Debug)]
#[serde(crate = "near_sdk::serde")]
pub struct EpochInfo {
    pub start_block: u64,
    pub end_block: Option<u64>,
    pub nullifier_root: String,
    pub nullifier_count: u32,
    pub finalized: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(crate = "near_sdk::serde")]
pub struct PoolStatus {
    pub total_deposits: u64,
    pub pool_balance: U128,
    pub current_epoch: u64,
    pub latest_root: String,
    pub domain_chain_id: u32,
    pub domain_app_id: u32,
}

// ── Contract ───────────────────────────────────────────

#[near_bindgen]
#[derive(BorshDeserialize, BorshSerialize, PanicOnDefault)]
pub struct PrivacyPool {
    /// Next leaf index
    next_leaf_index: u64,
    /// Filled subtrees at each level
    filled_subtrees: LookupMap<u32, String>,
    /// Root history (circular buffer)
    roots: LookupMap<u32, String>,
    /// Current root index
    current_root_index: u32,
    /// Spent nullifiers
    nullifier_spent: LookupMap<String, bool>,
    /// Existing commitments
    commitment_exists: LookupMap<String, bool>,
    /// Pool balance in yoctoNEAR
    pool_balance: u128,
    /// Current epoch ID
    current_epoch_id: u64,
    /// Epoch data
    epochs: UnorderedMap<u64, EpochInfo>,
    /// Epoch nullifiers
    epoch_nullifiers: LookupMap<u64, Vec<String>>,
    /// Remote epoch roots: "source_chain_id:epoch_id" → root
    remote_epoch_roots: LookupMap<String, String>,
    /// Governance account
    governance: AccountId,
    /// Authorized relayer/bridge for cross-chain sync
    authorized_relayer: Option<AccountId>,
    /// Domain chain ID for nullifier separation
    domain_chain_id: u32,
    /// Domain app ID
    domain_app_id: u32,
}

#[near_bindgen]
impl PrivacyPool {
    /// Initialize the privacy pool contract.
    #[init]
    pub fn new(
        governance: AccountId,
        domain_chain_id: u32,
        domain_app_id: u32,
    ) -> Self {
        assert!(!env::state_exists(), "Already initialized");

        let mut filled_subtrees = LookupMap::new(b"t");
        let mut roots = LookupMap::new(b"r");

        // Initialize Merkle tree zero values
        let mut current_zero = ZERO_HASH.to_string();
        for level in 0..TREE_DEPTH {
            filled_subtrees.insert(&level, &current_zero);
            current_zero = poseidon_hash_hex(&current_zero, &current_zero);
        }
        roots.insert(&0u32, &current_zero);

        let mut epochs = UnorderedMap::new(b"e");
        let mut epoch_nullifiers = LookupMap::new(b"en");
        epochs.insert(
            &0u64,
            &EpochInfo {
                start_block: env::block_height(),
                end_block: None,
                nullifier_root: ZERO_HASH.to_string(),
                nullifier_count: 0,
                finalized: false,
            },
        );
        epoch_nullifiers.insert(&0u64, &vec![]);

        Self {
            next_leaf_index: 0,
            filled_subtrees,
            roots,
            current_root_index: 0,
            nullifier_spent: LookupMap::new(b"n"),
            commitment_exists: LookupMap::new(b"c"),
            pool_balance: 0,
            current_epoch_id: 0,
            epochs,
            epoch_nullifiers,
            remote_epoch_roots: LookupMap::new(b"rr"),
            governance,
            authorized_relayer: None,
            domain_chain_id,
            domain_app_id,
        }
    }

    // ── Deposit ────────────────────────────────────────

    /// Deposit NEAR tokens into the privacy pool.
    /// Attach the deposit amount as NEAR tokens to this call.
    #[payable]
    pub fn deposit(&mut self, commitment: String) {
        let amount = env::attached_deposit();
        assert!(
            amount > NearToken::from_yoctonear(0),
            "Deposit amount must be non-zero"
        );
        assert!(
            !self.commitment_exists.contains_key(&commitment),
            "Commitment already exists"
        );

        self.commitment_exists.insert(&commitment, &true);
        let leaf_index = self.insert_leaf(&commitment);
        self.pool_balance += amount.as_yoctonear();

        env::log_str(&format!(
            "EVENT_JSON:{{\"standard\":\"privacy-pool\",\"version\":\"1.0.0\",\"event\":\"deposit\",\"data\":{{\"commitment\":\"{}\",\"leaf_index\":{},\"amount\":\"{}\"}}}}",
            commitment, leaf_index, amount.as_yoctonear()
        ));
    }

    // ── Transfer ───────────────────────────────────────

    /// Execute a private transfer within the pool.
    pub fn transfer(
        &mut self,
        proof: String,
        merkle_root: String,
        nullifiers: Vec<String>,
        output_commitments: Vec<String>,
    ) {
        assert!(nullifiers.len() == 2, "Exactly 2 nullifiers required");
        assert!(
            output_commitments.len() == 2,
            "Exactly 2 output commitments required"
        );

        assert!(self.is_known_root(&merkle_root), "Unknown Merkle root");
        self.check_and_spend_nullifiers(&nullifiers);

        // Verify ZK proof
        assert!(
            verify_proof_placeholder(&proof, &merkle_root, &nullifiers, &output_commitments),
            "Invalid ZK proof"
        );

        self.insert_leaf(&output_commitments[0]);
        self.insert_leaf(&output_commitments[1]);

        env::log_str(&format!(
            "EVENT_JSON:{{\"standard\":\"privacy-pool\",\"version\":\"1.0.0\",\"event\":\"transfer\",\"data\":{{\"nullifier_0\":\"{}\",\"nullifier_1\":\"{}\",\"output_0\":\"{}\",\"output_1\":\"{}\"}}}}",
            nullifiers[0], nullifiers[1], output_commitments[0], output_commitments[1]
        ));
    }

    // ── Withdraw ───────────────────────────────────────

    /// Withdraw NEAR tokens from the privacy pool.
    pub fn withdraw(
        &mut self,
        proof: String,
        merkle_root: String,
        nullifiers: Vec<String>,
        output_commitments: Vec<String>,
        recipient: AccountId,
        exit_value: U128,
    ) -> Promise {
        assert!(nullifiers.len() == 2, "Exactly 2 nullifiers required");
        assert!(
            output_commitments.len() == 2,
            "Exactly 2 output commitments required"
        );
        let exit_amount: u128 = exit_value.into();
        assert!(exit_amount > 0, "Withdrawal must be non-zero");
        assert!(
            exit_amount <= self.pool_balance,
            "Insufficient pool balance"
        );

        assert!(self.is_known_root(&merkle_root), "Unknown Merkle root");
        self.check_and_spend_nullifiers(&nullifiers);

        assert!(
            verify_proof_placeholder(&proof, &merkle_root, &nullifiers, &output_commitments),
            "Invalid ZK proof"
        );

        self.insert_leaf(&output_commitments[0]);
        self.insert_leaf(&output_commitments[1]);
        self.pool_balance -= exit_amount;

        env::log_str(&format!(
            "EVENT_JSON:{{\"standard\":\"privacy-pool\",\"version\":\"1.0.0\",\"event\":\"withdraw\",\"data\":{{\"recipient\":\"{}\",\"amount\":\"{}\"}}}}",
            recipient, exit_amount
        ));

        Promise::new(recipient).transfer(NearToken::from_yoctonear(exit_amount))
    }

    // ── Epoch Management ───────────────────────────────

    /// Set the authorized relayer account for cross-chain sync.
    pub fn set_authorized_relayer(&mut self, relayer: Option<AccountId>) {
        assert_eq!(
            env::predecessor_account_id(),
            self.governance,
            "Only governance can set relayer"
        );
        self.authorized_relayer = relayer;
    }

    /// Finalize the current epoch. Only callable by governance.
    pub fn finalize_epoch(&mut self) {
        assert_eq!(
            env::predecessor_account_id(),
            self.governance,
            "Only governance can finalize epoch"
        );
        let epoch_id = self.current_epoch_id;
        let mut epoch = self.epochs.get(&epoch_id).expect("Epoch not found");
        assert!(!epoch.finalized, "Epoch already finalized");

        let nullifiers = self
            .epoch_nullifiers
            .get(&epoch_id)
            .unwrap_or_default();

        let nullifier_root = compute_nullifier_root(&nullifiers);
        let count = nullifiers.len() as u32;

        epoch.nullifier_root = nullifier_root.clone();
        epoch.nullifier_count = count;
        epoch.end_block = Some(env::block_height());
        epoch.finalized = true;
        self.epochs.insert(&epoch_id, &epoch);

        // Start new epoch
        let new_epoch_id = epoch_id + 1;
        self.current_epoch_id = new_epoch_id;
        self.epochs.insert(
            &new_epoch_id,
            &EpochInfo {
                start_block: env::block_height(),
                end_block: None,
                nullifier_root: ZERO_HASH.to_string(),
                nullifier_count: 0,
                finalized: false,
            },
        );
        self.epoch_nullifiers.insert(&new_epoch_id, &vec![]);

        env::log_str(&format!(
            "EVENT_JSON:{{\"standard\":\"privacy-pool\",\"version\":\"1.0.0\",\"event\":\"epoch_finalized\",\"data\":{{\"epoch_id\":{},\"nullifier_root\":\"{}\",\"nullifier_count\":{}}}}}",
            epoch_id, nullifier_root, count
        ));
    }

    /// Receive epoch root from remote chain. Only callable by governance or authorized relayer.
    pub fn sync_epoch_root(
        &mut self,
        source_chain_id: u32,
        epoch_id: u64,
        nullifier_root: String,
    ) {
        let caller = env::predecessor_account_id();
        let is_authorized = caller == self.governance
            || self
                .authorized_relayer
                .as_ref()
                .map_or(false, |r| &caller == r);
        assert!(is_authorized, "Only governance or authorized relayer can sync epoch roots");
        assert!(!nullifier_root.is_empty(), "Nullifier root cannot be empty");

        let key = format!("{}:{}", source_chain_id, epoch_id);
        self.remote_epoch_roots.insert(&key, &nullifier_root);

        env::log_str(&format!(
            "EVENT_JSON:{{\"standard\":\"privacy-pool\",\"version\":\"1.0.0\",\"event\":\"remote_epoch_root\",\"data\":{{\"source_chain_id\":{},\"epoch_id\":{},\"nullifier_root\":\"{}\"}}}}",
            source_chain_id, epoch_id, nullifier_root
        ));
    }

    // ── View Methods ───────────────────────────────────

    pub fn get_pool_status(&self) -> PoolStatus {
        let root = self
            .roots
            .get(&self.current_root_index)
            .unwrap_or_else(|| ZERO_HASH.to_string());

        PoolStatus {
            total_deposits: self.next_leaf_index,
            pool_balance: U128(self.pool_balance),
            current_epoch: self.current_epoch_id,
            latest_root: root,
            domain_chain_id: self.domain_chain_id,
            domain_app_id: self.domain_app_id,
        }
    }

    pub fn is_nullifier_spent(&self, nullifier: String) -> bool {
        self.nullifier_spent.contains_key(&nullifier)
    }

    pub fn get_latest_root(&self) -> String {
        self.roots
            .get(&self.current_root_index)
            .unwrap_or_else(|| ZERO_HASH.to_string())
    }

    pub fn get_epoch_info(&self, epoch_id: u64) -> Option<EpochInfo> {
        self.epochs.get(&epoch_id)
    }

    pub fn get_remote_epoch_root(
        &self,
        source_chain_id: u32,
        epoch_id: u64,
    ) -> Option<String> {
        let key = format!("{}:{}", source_chain_id, epoch_id);
        self.remote_epoch_roots.get(&key)
    }

    // ── Internal Methods ───────────────────────────────

    fn insert_leaf(&mut self, leaf_hex: &str) -> u64 {
        let max_leaves = 2u64.pow(TREE_DEPTH);
        assert!(self.next_leaf_index < max_leaves, "Merkle tree is full");

        let idx = self.next_leaf_index;
        let mut current_index = idx;
        let mut current_hash = leaf_hex.to_string();

        for level in 0..TREE_DEPTH {
            if current_index % 2 == 0 {
                self.filled_subtrees.insert(&level, &current_hash);
                let zero = zero_hash(level);
                current_hash = poseidon_hash_hex(&current_hash, &zero);
            } else {
                let sibling = self
                    .filled_subtrees
                    .get(&level)
                    .unwrap_or_else(|| ZERO_HASH.to_string());
                current_hash = poseidon_hash_hex(&sibling, &current_hash);
            }
            current_index /= 2;
        }

        let new_root_idx = (self.current_root_index + 1) % ROOT_HISTORY_SIZE;
        self.roots.insert(&new_root_idx, &current_hash);
        self.current_root_index = new_root_idx;
        self.next_leaf_index = idx + 1;

        idx
    }

    fn is_known_root(&self, root: &str) -> bool {
        if root == ZERO_HASH {
            return false;
        }
        let mut idx = self.current_root_index;
        for _ in 0..ROOT_HISTORY_SIZE {
            if let Some(stored) = self.roots.get(&idx) {
                if stored == root {
                    return true;
                }
            }
            if idx == 0 {
                idx = ROOT_HISTORY_SIZE - 1;
            } else {
                idx -= 1;
            }
        }
        false
    }

    fn check_and_spend_nullifiers(&mut self, nullifiers: &[String]) {
        let epoch_id = self.current_epoch_id;
        let mut epoch_nuls = self
            .epoch_nullifiers
            .get(&epoch_id)
            .unwrap_or_default();

        for nullifier in nullifiers {
            assert!(
                !self.nullifier_spent.contains_key(nullifier),
                "Nullifier already spent: {}",
                nullifier
            );
            self.nullifier_spent.insert(nullifier, &true);

            assert!(
                epoch_nuls.len() < MAX_NULLIFIERS_PER_EPOCH,
                "Epoch nullifier overflow"
            );
            epoch_nuls.push(nullifier.clone());
        }

        self.epoch_nullifiers.insert(&epoch_id, &epoch_nuls);
    }
}

// ── Free Functions ─────────────────────────────────────

/// Proof verification — TESTNET ONLY.
///
/// Performs structural validation of the proof envelope. In production,
/// this should call a co-deployed ZK verifier contract or use a NEAR
/// Structural proof verification — validates format and public input integrity.
///
/// TESTNET ONLY. For mainnet, deploy a co-deployed ZK verifier contract
/// or use a NEAR precompile for Groth16/Halo2 verification.
///
/// # Structural checks performed:
/// - Proof is valid hex and >= 384 hex chars (192 bytes Groth16 minimum)
/// - Proof is not all-zero (trivially forged)
/// - No duplicate nullifiers (double-spend prevention)
/// - All output commitments are non-zero and distinct
/// - Merkle root is non-zero
fn verify_proof_placeholder(
    proof: &str,
    merkle_root: &str,
    nullifiers: &[String],
    output_commitments: &[String],
) -> bool {
    // Minimum proof size: hex-encoded 192 bytes = 384 hex chars
    if proof.len() < 384 {
        return false;
    }
    // Maximum proof size
    if proof.len() > 8192 {
        return false;
    }
    // Proof must be valid hex
    if !proof.chars().all(|c| c.is_ascii_hexdigit()) {
        return false;
    }
    // Proof must be even length (complete bytes)
    if proof.len() % 2 != 0 {
        return false;
    }
    // Reject all-zero proof
    if proof.chars().all(|c| c == '0') {
        return false;
    }
    // No duplicate nullifiers
    if nullifiers.len() >= 2 && nullifiers[0] == nullifiers[1] {
        return false;
    }
    // Nullifiers must be non-zero
    for nul in nullifiers {
        if nul.is_empty() || nul.chars().all(|c| c == '0') {
            return false;
        }
    }
    // Non-zero root
    if merkle_root.is_empty() || merkle_root.chars().all(|c| c == '0') {
        return false;
    }
    // Non-zero and distinct output commitments
    for cm in output_commitments {
        if cm.is_empty() || cm.chars().all(|c| c == '0') {
            return false;
        }
    }
    if output_commitments.len() >= 2 && output_commitments[0] == output_commitments[1] {
        return false;
    }
    true
}

fn compute_nullifier_root(nullifiers: &[String]) -> String {
    if nullifiers.is_empty() {
        return ZERO_HASH.to_string();
    }
    let mut current = nullifiers[0].clone();
    for nul in &nullifiers[1..] {
        current = poseidon_hash_hex(&current, nul);
    }
    current
}

/// Poseidon hash — domain-separated hash for ZK-compatible Merkle trees.
///
/// Uses NEAR's native keccak256 with a "Poseidon" domain tag to provide
/// a deterministic, collision-resistant hash aligned across all privacy
/// pool deployments. For mainnet, replace with a WASM-compiled BN254
/// Poseidon (e.g., light-poseidon) for exact circuit alignment.
fn poseidon_hash_hex(left: &str, right: &str) -> String {
    let mut data = Vec::with_capacity(8 + left.len() + right.len());
    data.extend_from_slice(b"Poseidon");
    data.extend_from_slice(left.as_bytes());
    data.extend_from_slice(right.as_bytes());
    let hash = env::keccak256(&data);
    hex::encode(hash)
}

fn zero_hash(level: u32) -> String {
    let mut z = ZERO_HASH.to_string();
    for _ in 0..level {
        z = poseidon_hash_hex(&z, &z);
    }
    z
}
