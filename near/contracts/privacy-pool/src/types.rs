//! Type definitions for the NEAR Privacy Pool contract.

use near_sdk::borsh::{BorshDeserialize, BorshSerialize};
use near_sdk::json_types::U128;
use serde::{Deserialize, Serialize};

/// Information about a finalized or in-progress epoch.
#[derive(BorshDeserialize, BorshSerialize, Serialize, Deserialize, Clone, Debug)]
#[serde(crate = "near_sdk::serde")]
pub struct EpochInfo {
    pub start_block: u64,
    pub end_block: Option<u64>,
    pub nullifier_root: String,
    pub nullifier_count: u32,
    pub finalized: bool,
}

/// Summary of pool state returned by `get_pool_status`.
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
