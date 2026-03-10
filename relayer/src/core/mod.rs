//! Core relay engine — retry logic, transaction lifecycle, nonce management,
//! and adapter-aware epoch root dispatch.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::adapters::{
    awm::AwmAdapter, ibc::IbcAdapter, rainbow::RainbowAdapter, xcm::XcmAdapter,
    BridgeAdapter, EpochRootMessage,
};
use crate::config::{ChainWatchConfig, RelayerConfig};

/// Maximum retry attempts before giving up on a relay.
const MAX_RETRIES: u32 = 5;

/// Base backoff in milliseconds (doubles each retry).
const BASE_BACKOFF_MS: u64 = 1_000;

/// Transaction lifecycle states.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TxState {
    Pending,
    Submitted { tx_hash: String },
    Confirmed { tx_hash: String, block: u64 },
    Finalized { tx_hash: String },
    Failed { reason: String },
}

/// A relay task queued for processing.
#[derive(Debug, Clone)]
pub struct RelayTask {
    pub target_chain_id: u64,
    pub message: EpochRootMessage,
    pub state: TxState,
    pub retries: u32,
}

/// Per-chain nonce tracker to avoid nonce collisions.
#[derive(Debug, Default)]
pub struct NonceManager {
    nonces: HashMap<u64, u64>,
}

impl NonceManager {
    pub fn next(&mut self, chain_id: u64) -> u64 {
        let n = self.nonces.entry(chain_id).or_insert(0);
        let current = *n;
        *n += 1;
        current
    }

    pub fn set(&mut self, chain_id: u64, nonce: u64) {
        self.nonces.insert(chain_id, nonce);
    }
}

/// The core relay engine that routes epoch roots through the correct adapter.
pub struct RelayEngine {
    adapters: Vec<Box<dyn BridgeAdapter>>,
    nonce_mgr: Arc<Mutex<NonceManager>>,
    config: RelayerConfig,
}

impl RelayEngine {
    /// Create a new engine, registering all known bridge adapters.
    pub fn new(config: RelayerConfig) -> Self {
        let adapters: Vec<Box<dyn BridgeAdapter>> = vec![
            Box::new(AwmAdapter::new()),
            Box::new(XcmAdapter::new()),
            Box::new(IbcAdapter::new()),
            Box::new(RainbowAdapter::new()),
        ];

        Self {
            adapters,
            nonce_mgr: Arc::new(Mutex::new(NonceManager::default())),
            config,
        }
    }

    /// Find the appropriate adapter for a given chain.
    fn adapter_for(&self, chain_id: u64) -> Option<&dyn BridgeAdapter> {
        self.adapters
            .iter()
            .find(|a| a.supports_chain(chain_id))
            .map(|a| a.as_ref())
    }

    /// Find chain config by ID.
    fn chain_config(&self, chain_id: u64) -> Option<&ChainWatchConfig> {
        self.config.chains.iter().find(|c| c.chain_id == chain_id)
    }

    /// Dispatch a single relay task with retry + exponential backoff.
    pub async fn dispatch(&self, task: &mut RelayTask) -> Result<String, String> {
        let adapter = self
            .adapter_for(task.target_chain_id)
            .ok_or_else(|| format!("no adapter for chain {}", task.target_chain_id))?;

        let chain_cfg = self
            .chain_config(task.target_chain_id)
            .ok_or_else(|| format!("chain {} not in config", task.target_chain_id))?;

        loop {
            task.state = TxState::Pending;

            match adapter.send_epoch_root(chain_cfg, &task.message).await {
                Ok(tx_hash) => {
                    task.state = TxState::Submitted {
                        tx_hash: tx_hash.clone(),
                    };
                    tracing::info!(
                        chain_id = task.target_chain_id,
                        tx_hash = %tx_hash,
                        protocol = adapter.protocol_name(),
                        "epoch root relayed"
                    );
                    return Ok(tx_hash);
                }
                Err(e) => {
                    task.retries += 1;
                    if task.retries >= MAX_RETRIES {
                        let reason =
                            format!("max retries ({}) exceeded: {}", MAX_RETRIES, e);
                        task.state = TxState::Failed {
                            reason: reason.clone(),
                        };
                        tracing::error!(
                            chain_id = task.target_chain_id,
                            error = %e,
                            retries = task.retries,
                            "relay permanently failed"
                        );
                        return Err(reason);
                    }

                    let backoff =
                        BASE_BACKOFF_MS * 2u64.saturating_pow(task.retries - 1);
                    tracing::warn!(
                        chain_id = task.target_chain_id,
                        error = %e,
                        retry = task.retries,
                        backoff_ms = backoff,
                        "relay failed, retrying"
                    );
                    tokio::time::sleep(std::time::Duration::from_millis(backoff)).await;
                }
            }
        }
    }

    /// Process a batch of relay tasks, dispatching each with retries.
    pub async fn process_batch(&self, tasks: &mut [RelayTask]) -> Vec<Result<String, String>> {
        let mut results = Vec::with_capacity(tasks.len());
        for task in tasks.iter_mut() {
            results.push(self.dispatch(task).await);
        }
        results
    }

    /// Build a relay task from an epoch event destined for a target chain.
    pub fn build_task(
        source_chain_id: u64,
        target_chain_id: u64,
        epoch_id: u64,
        nullifier_root: [u8; 32],
        nullifier_count: u32,
    ) -> RelayTask {
        RelayTask {
            target_chain_id,
            message: EpochRootMessage {
                source_chain_id,
                epoch_id,
                nullifier_root,
                nullifier_count,
            },
            state: TxState::Pending,
            retries: 0,
        }
    }
}

/// Compute exponential backoff duration (capped at ~32 s).
pub fn backoff_duration(attempt: u32) -> std::time::Duration {
    let ms = BASE_BACKOFF_MS * 2u64.saturating_pow(attempt.min(5));
    std::time::Duration::from_millis(ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_manager_increments() {
        let mut mgr = NonceManager::default();
        assert_eq!(mgr.next(43114), 0);
        assert_eq!(mgr.next(43114), 1);
        assert_eq!(mgr.next(1284), 0);
        assert_eq!(mgr.next(43114), 2);
    }

    #[test]
    fn backoff_caps_at_32s() {
        let d = backoff_duration(10);
        assert_eq!(d, std::time::Duration::from_millis(32_000));
    }

    #[test]
    fn build_task_initialises_correctly() {
        let task = RelayEngine::build_task(43114, 1284, 42, [0xAA; 32], 64);
        assert_eq!(task.target_chain_id, 1284);
        assert_eq!(task.message.epoch_id, 42);
        assert_eq!(task.retries, 0);
        assert_eq!(task.state, TxState::Pending);
    }
}
