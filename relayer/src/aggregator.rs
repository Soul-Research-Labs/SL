use crate::{EpochEvent, RelayCommand};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use tracing::{debug, info, warn};

use crate::config::RelayerConfig;

/// Run the event aggregator.
///
/// Receives epoch events from chain watchers, applies metadata resistance
/// (batching, jitter), and produces relay commands for dispatch.
pub async fn run_aggregator(
    config: Arc<RelayerConfig>,
    mut event_rx: mpsc::Receiver<EpochEvent>,
    cmd_tx: mpsc::Sender<RelayCommand>,
) {
    info!("Event aggregator started");

    let mr = &config.metadata_resistance;
    let mut batch: Vec<EpochEvent> = Vec::new();
    let batch_timeout = Duration::from_millis(mr.batch_timeout_ms);

    loop {
        let event = if mr.batching_enabled {
            // Wait for event or batch timeout
            tokio::select! {
                ev = event_rx.recv() => ev,
                _ = sleep(batch_timeout) => {
                    // Flush current batch on timeout
                    if !batch.is_empty() {
                        flush_batch(&config, &batch, &cmd_tx).await;
                        batch.clear();
                    }
                    continue;
                }
            }
        } else {
            event_rx.recv().await
        };

        match event {
            Some(ev) => {
                info!(
                    "Epoch event: chain={} epoch={} nullifiers={} root=0x{}",
                    ev.chain_name,
                    ev.epoch_id,
                    ev.nullifier_count,
                    hex::encode(&ev.nullifier_root[..8])
                );

                if mr.batching_enabled {
                    batch.push(ev);
                    if batch.len() >= mr.batch_size {
                        flush_batch(&config, &batch, &cmd_tx).await;
                        batch.clear();
                    }
                } else {
                    // Immediate relay with optional jitter
                    if mr.jitter_enabled && mr.max_jitter_ms > 0 {
                        let jitter = rand_jitter(mr.max_jitter_ms);
                        debug!("Applying {}ms jitter before relay", jitter);
                        sleep(Duration::from_millis(jitter)).await;
                    }
                    dispatch_event(&config, &ev, &cmd_tx).await;
                }
            }
            None => {
                // All watchers dropped — flush remaining and exit
                if !batch.is_empty() {
                    flush_batch(&config, &batch, &cmd_tx).await;
                }
                info!("All watchers closed, aggregator shutting down");
                break;
            }
        }
    }
}

/// Flush a batch of events — dispatch all with jitter spacing
async fn flush_batch(
    config: &RelayerConfig,
    batch: &[EpochEvent],
    cmd_tx: &mpsc::Sender<RelayCommand>,
) {
    info!("Flushing batch of {} epoch events", batch.len());

    for event in batch {
        if config.metadata_resistance.jitter_enabled {
            let jitter = rand_jitter(config.metadata_resistance.max_jitter_ms);
            sleep(Duration::from_millis(jitter)).await;
        }
        dispatch_event(config, event, cmd_tx).await;
    }
}

/// Dispatch relay commands for a single epoch event
async fn dispatch_event(
    config: &RelayerConfig,
    event: &EpochEvent,
    cmd_tx: &mpsc::Sender<RelayCommand>,
) {
    // 1. Submit to universal registry
    if let Err(e) = cmd_tx
        .send(RelayCommand::SubmitToRegistry {
            source_chain_id: event.chain_id,
            epoch_id: event.epoch_id,
            nullifier_root: event.nullifier_root,
            nullifier_count: event.nullifier_count,
        })
        .await
    {
        warn!("Failed to send registry command: {}", e);
    }

    // 2. Relay to all other chains
    for chain in &config.chains {
        if chain.chain_id == event.chain_id {
            continue; // Skip source chain
        }
        if chain.bridge_adapter_address.is_none() {
            continue; // No bridge adapter — can't relay
        }

        if let Err(e) = cmd_tx
            .send(RelayCommand::SendToChain {
                target_chain_id: chain.chain_id,
                source_chain_id: event.chain_id,
                epoch_id: event.epoch_id,
                nullifier_root: event.nullifier_root,
            })
            .await
        {
            warn!(
                "Failed to send relay command to chain {}: {}",
                chain.chain_id, e
            );
        }
    }
}

/// Generate a random jitter value in [0, max_ms)
fn rand_jitter(max_ms: u64) -> u64 {
    // Use a simple non-cryptographic source for timing jitter
    // (not security-critical — this is for traffic analysis resistance)
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u64;
    seed % max_ms
}
