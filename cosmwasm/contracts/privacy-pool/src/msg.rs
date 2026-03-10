use cosmwasm_schema::{cw_serde, QueryResponses};
use cosmwasm_std::Uint128;

// ── Instantiate ────────────────────────────────────────────

#[cw_serde]
pub struct InstantiateMsg {
    /// Merkle tree depth (default: 32)
    pub tree_depth: u32,
    /// Epoch duration in blocks
    pub epoch_duration: u64,
    /// Maximum nullifiers per epoch
    pub max_nullifiers_per_epoch: u32,
    /// Root history size
    pub root_history_size: u32,
    /// Chain domain ID for nullifier separation
    pub domain_chain_id: u32,
    /// Application domain ID
    pub domain_app_id: u32,
    /// Governance address (can update verifier, bridge adapters)
    pub governance: String,
    /// Accepted token denomination (e.g. "uatom", "aevmos", "uosmo")
    pub accepted_denom: String,
}

// ── Execute ────────────────────────────────────────────────

#[cw_serde]
pub enum ExecuteMsg {
    /// Deposit (shield) tokens into the privacy pool
    Deposit {
        commitment: String, // hex-encoded 32-byte commitment
    },
    /// Execute a private transfer with ZK proof
    Transfer {
        proof: String,            // hex-encoded proof bytes
        merkle_root: String,      // hex-encoded 32 bytes
        nullifiers: [String; 2],  // hex-encoded nullifiers
        output_commitments: [String; 2],
    },
    /// Withdraw (unshield) tokens from the privacy pool
    Withdraw {
        proof: String,
        merkle_root: String,
        nullifiers: [String; 2],
        output_commitments: [String; 2],
        recipient: String,
        exit_value: Uint128,
    },
    /// Finalize current epoch
    FinalizeEpoch {},
    /// Receive epoch root from remote chain (via IBC)
    SyncEpochRoot {
        source_chain_id: u32,
        epoch_id: u64,
        nullifier_root: String,
    },
    /// Update governance address
    UpdateGovernance {
        new_governance: String,
    },
    /// Set authorized relayer for cross-chain sync (governance only)
    SetAuthorizedRelayer {
        relayer: Option<String>,
    },
}

// ── Query ──────────────────────────────────────────────────

#[cw_serde]
#[derive(QueryResponses)]
pub enum QueryMsg {
    /// Get the latest Merkle root
    #[returns(RootResponse)]
    LatestRoot {},
    /// Check if a root is in the history
    #[returns(bool)]
    IsKnownRoot { root: String },
    /// Check if a nullifier has been spent
    #[returns(bool)]
    IsSpent { nullifier: String },
    /// Get pool status
    #[returns(PoolStatusResponse)]
    PoolStatus {},
    /// Get epoch info
    #[returns(EpochInfoResponse)]
    EpochInfo { epoch_id: u64 },
    /// Get remote epoch root
    #[returns(Option<String>)]
    RemoteEpochRoot {
        source_chain_id: u32,
        epoch_id: u64,
    },
}

// ── Query Responses ────────────────────────────────────────

#[cw_serde]
pub struct RootResponse {
    pub root: String,
}

#[cw_serde]
pub struct PoolStatusResponse {
    pub total_deposits: u64,
    pub pool_balance: Uint128,
    pub current_epoch: u64,
    pub latest_root: String,
}

#[cw_serde]
pub struct EpochInfoResponse {
    pub epoch_id: u64,
    pub nullifier_root: String,
    pub nullifier_count: u32,
    pub finalized: bool,
}
