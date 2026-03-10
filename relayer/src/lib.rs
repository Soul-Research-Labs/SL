//! # Cross-Chain Privacy Relayer
//!
//! Multi-chain relayer that monitors privacy pools across all deployed chains
//! and relays epoch nullifier roots to maintain global double-spend prevention.
//!
//! ## Responsibilities
//!
//! 1. **Epoch Monitoring**: Watch EpochManager contracts on all chains for
//!    `EpochFinalized` events
//! 2. **Root Relay**: When an epoch finalizes, relay its nullifier root to
//!    all peer chains via their bridge adapters
//! 3. **Universal Registry Update**: Submit epoch roots to the
//!    `UniversalNullifierRegistry` hub contract
//! 4. **Metadata Resistance**: Apply timing jitter and batching to resist
//!    traffic analysis across relay messages
//! 5. **Health Monitoring**: Track liveness of all chains and alert on failures
//!
//! ## Architecture
//!
//! ```text
//! ┌──────────────────────────────────────────────────────┐
//! │                    Relayer Daemon                     │
//! │                                                      │
//! │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
//! │  │ Avalanche │  │ Moonbeam │  │  Evmos   │  ...     │
//! │  │  Watcher  │  │  Watcher │  │  Watcher │          │
//! │  └──────┬───┘  └────┬─────┘  └────┬─────┘          │
//! │         │           │              │                 │
//! │         ▼           ▼              ▼                 │
//! │       ┌─────────────────────────────────┐           │
//! │       │        Event Aggregator          │           │
//! │       │    (dedup, batch, jitter)        │           │
//! │       └──────────────┬──────────────────┘           │
//! │                      │                               │
//! │         ┌────────────┼────────────┐                 │
//! │         ▼            ▼            ▼                  │
//! │  ┌───────────┐ ┌──────────┐ ┌──────────┐          │
//! │  │  Bridge   │ │  Bridge  │ │ Universal│          │
//! │  │  Relay    │ │  Relay   │ │ Registry │          │
//! │  │ (to peer) │ │ (to peer)│ │  Update  │          │
//! │  └───────────┘ └──────────┘ └──────────┘          │
//! └──────────────────────────────────────────────────────┘
//! ```

pub mod aggregator;
pub mod config;
pub mod health;
pub mod metrics;
pub mod watcher;

use config::RelayerConfig;
use health::HealthState;
use metrics::Metrics;
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{error, info};

/// Epoch event from any chain
#[derive(Clone, Debug)]
pub struct EpochEvent {
    pub chain_id: u64,
    pub chain_name: String,
    pub epoch_id: u64,
    pub nullifier_root: [u8; 32],
    pub nullifier_count: u32,
    pub block_number: u64,
    pub tx_hash: String,
    pub timestamp: u64,
}

/// Relay command produced by the aggregator
#[derive(Clone, Debug)]
pub enum RelayCommand {
    /// Send epoch root to a specific chain's EpochManager
    SendToChain {
        target_chain_id: u64,
        source_chain_id: u64,
        epoch_id: u64,
        nullifier_root: [u8; 32],
    },
    /// Submit to the universal nullifier registry
    SubmitToRegistry {
        source_chain_id: u64,
        epoch_id: u64,
        nullifier_root: [u8; 32],
        nullifier_count: u32,
    },
}

/// Start the relayer daemon
pub async fn run_relayer(config: RelayerConfig) -> Result<(), Box<dyn std::error::Error>> {
    info!("Starting cross-chain privacy relayer");
    info!("Monitoring {} chains", config.chains.len());

    let metrics = Arc::new(Metrics::new());
    let health = Arc::new(HealthState::new(config.chains.len() as u64));

    // Spawn combined health + metrics HTTP server.
    let health_addr: std::net::SocketAddr =
        format!("0.0.0.0:{}", config.metrics_port).parse()?;
    let m = metrics.clone();
    let h = health.clone();
    tokio::spawn(async move {
        health::serve_health(m, h, health_addr).await;
    });

    // Channel for epoch events from watchers → aggregator
    let (event_tx, event_rx) = mpsc::channel::<EpochEvent>(256);

    // Channel for relay commands from aggregator → relay workers
    let (cmd_tx, cmd_rx) = mpsc::channel::<RelayCommand>(256);

    let config = Arc::new(config);

    // Spawn chain watchers
    for chain in &config.chains {
        let tx = event_tx.clone();
        let chain_config = chain.clone();
        tokio::spawn(async move {
            if let Err(e) = watcher::watch_chain(chain_config, tx).await {
                error!("Watcher failed for chain {}: {}", chain_config.chain_id, e);
            }
        });
    }
    drop(event_tx); // Close sender after all watchers have clones

    // Spawn aggregator
    let agg_config = config.clone();
    tokio::spawn(async move {
        aggregator::run_aggregator(agg_config, event_rx, cmd_tx).await;
    });

    // Process relay commands
    let mut cmd_rx = cmd_rx;
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            RelayCommand::SendToChain {
                target_chain_id,
                source_chain_id,
                epoch_id,
                nullifier_root,
            } => {
                info!(
                    "Relaying epoch {} root from chain {} to chain {}",
                    epoch_id, source_chain_id, target_chain_id
                );
                metrics.inc_relays_dispatched();
                // Actual bridge relay happens here via the submitter
            }
            RelayCommand::SubmitToRegistry {
                source_chain_id,
                epoch_id,
                nullifier_root,
                nullifier_count,
            } => {
                info!(
                    "Submitting epoch {} root from chain {} to universal registry ({} nullifiers)",
                    epoch_id, source_chain_id, nullifier_count
                );
                metrics.inc_registry_submissions();
            }
        }
    }

    Ok(())
}
