use cosmwasm_std::Uint128;
use cw_storage_plus::{Item, Map};
use serde::{Deserialize, Serialize};

// ── Merkle Tree State ──────────────────────────────────────

/// Next leaf index in the Merkle tree
pub const NEXT_LEAF_INDEX: Item<u64> = Item::new("next_leaf_idx");

/// Filled subtrees: level → hash (hex-encoded)
pub const FILLED_SUBTREES: Map<u32, String> = Map::new("filled_sub");

/// Root history: index → hash (hex-encoded)
pub const ROOTS: Map<u32, String> = Map::new("roots");

/// Current root index in the circular buffer
pub const CURRENT_ROOT_INDEX: Item<u32> = Item::new("curr_root_idx");

// ── Nullifier State ────────────────────────────────────────

/// Spent nullifiers: nullifier_hex → true
pub const NULLIFIER_SPENT: Map<&str, bool> = Map::new("nul_spent");

/// Existing commitments: commitment_hex → true
pub const COMMITMENT_EXISTS: Map<&str, bool> = Map::new("cm_exists");

// ── Pool State ─────────────────────────────────────────────

/// Total pool balance
pub const POOL_BALANCE: Item<Uint128> = Item::new("pool_bal");

// ── Epoch State ────────────────────────────────────────────

/// Current epoch ID
pub const CURRENT_EPOCH_ID: Item<u64> = Item::new("curr_epoch");

/// Epoch info: epoch_id → EpochInfo
pub const EPOCHS: Map<u64, EpochInfo> = Map::new("epochs");

/// Epoch nullifiers: epoch_id → Vec<String> (hex-encoded)
pub const EPOCH_NULLIFIERS: Map<u64, Vec<String>> = Map::new("epoch_nuls");

/// Remote epoch roots: (source_chain_id, epoch_id) → nullifier_root hex
pub const REMOTE_EPOCH_ROOTS: Map<(u32, u64), String> = Map::new("remote_roots");

// ── Config ─────────────────────────────────────────────────

pub const CONFIG: Item<Config> = Item::new("config");

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Config {
    pub tree_depth: u32,
    pub epoch_duration: u64,
    pub max_nullifiers_per_epoch: u32,
    pub root_history_size: u32,
    pub domain_chain_id: u32,
    pub domain_app_id: u32,
    pub governance: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct EpochInfo {
    pub start_height: u64,
    pub end_height: Option<u64>,
    pub nullifier_root: String,
    pub nullifier_count: u32,
    pub finalized: bool,
}
