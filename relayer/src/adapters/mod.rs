//! Bridge adapter trait and implementations for cross-chain epoch relay.
//!
//! Each adapter knows how to send an epoch root message to a specific
//! bridge protocol (AWM, XCM, IBC, Rainbow).

pub mod awm;
pub mod ibc;
pub mod rainbow;
pub mod xcm;

use async_trait::async_trait;
use crate::config::ChainWatchConfig;

/// Error type for bridge adapter operations.
#[derive(Debug, Clone)]
pub enum AdapterError {
    /// RPC call failed.
    Rpc(String),
    /// Transaction signing failed.
    Signing(String),
    /// Bridge-specific error (e.g., message format, routing).
    Bridge(String),
    /// The adapter does not support the target chain.
    UnsupportedChain(u64),
}

impl std::fmt::Display for AdapterError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rpc(msg) => write!(f, "RPC error: {}", msg),
            Self::Signing(msg) => write!(f, "signing error: {}", msg),
            Self::Bridge(msg) => write!(f, "bridge error: {}", msg),
            Self::UnsupportedChain(id) => write!(f, "unsupported chain: {}", id),
        }
    }
}

impl std::error::Error for AdapterError {}

/// Payload for a cross-chain epoch root message.
#[derive(Debug, Clone)]
pub struct EpochRootMessage {
    pub source_chain_id: u64,
    pub epoch_id: u64,
    pub nullifier_root: [u8; 32],
    pub nullifier_count: u32,
}

/// Common trait for all bridge adapters.
#[async_trait]
pub trait BridgeAdapter: Send + Sync {
    /// Human-readable name of the bridge protocol.
    fn protocol_name(&self) -> &str;

    /// Whether this adapter supports relaying to the given chain.
    fn supports_chain(&self, chain_id: u64) -> bool;

    /// Send an epoch root message to a target chain via this bridge.
    async fn send_epoch_root(
        &self,
        target_chain: &ChainWatchConfig,
        message: &EpochRootMessage,
    ) -> Result<String, AdapterError>;

    /// Estimate the fee (in wei) for sending to the target chain.
    async fn estimate_fee(
        &self,
        target_chain: &ChainWatchConfig,
    ) -> Result<u128, AdapterError>;
}
