use crate::config::ChainWatchConfig;
use crate::EpochEvent;
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

/// Watch a single chain for EpochFinalized events.
///
/// Uses WebSocket subscription when available, falls back to polling.
pub async fn watch_chain(
    config: ChainWatchConfig,
    event_tx: mpsc::Sender<EpochEvent>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    info!(
        "Starting watcher for {} (chain_id={})",
        config.name, config.chain_id
    );

    // Try WebSocket first, fall back to polling
    match watch_via_ws(&config, &event_tx).await {
        Ok(()) => Ok(()),
        Err(e) => {
            warn!(
                "WebSocket watcher failed for {}: {}, falling back to polling",
                config.name, e
            );
            watch_via_polling(&config, &event_tx).await
        }
    }
}

/// Watch via WebSocket event subscription (preferred)
async fn watch_via_ws(
    config: &ChainWatchConfig,
    event_tx: &mpsc::Sender<EpochEvent>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use ethers::prelude::*;
    use std::sync::Arc;

    let provider = Provider::<Ws>::connect(&config.ws_rpc_url).await?;
    let client = Arc::new(provider);

    // EpochFinalized(uint256 epochId, bytes32 nullifierRoot, uint256 nullifierCount)
    let epoch_finalized_topic = H256::from(ethers::utils::keccak256(
        "EpochFinalized(uint256,bytes32,uint256)",
    ));

    let filter = Filter::new()
        .address(config.epoch_manager_address.parse::<Address>()?)
        .topic0(epoch_finalized_topic);

    let mut stream = client.subscribe_logs(&filter).await?;

    info!(
        "WebSocket subscription active for {} EpochManager at {}",
        config.name, config.epoch_manager_address
    );

    while let Some(log) = stream.next().await {
        match parse_epoch_finalized_log(&log, &config) {
            Ok(event) => {
                info!(
                    "Epoch finalized on {}: epoch={} nullifiers={}",
                    config.name, event.epoch_id, event.nullifier_count
                );

                // Wait for confirmations
                if config.confirmation_blocks > 0 {
                    wait_for_confirmations(
                        &client,
                        log.block_number.unwrap_or_default().as_u64(),
                        config.confirmation_blocks,
                    )
                    .await;
                }

                if let Err(e) = event_tx.send(event).await {
                    error!("Failed to send epoch event: {}", e);
                    break;
                }
            }
            Err(e) => {
                warn!("Failed to parse EpochFinalized log on {}: {}", config.name, e);
            }
        }
    }

    Ok(())
}

/// Watch via HTTP polling (fallback)
async fn watch_via_polling(
    config: &ChainWatchConfig,
    event_tx: &mpsc::Sender<EpochEvent>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use ethers::prelude::*;

    let provider = Provider::<Http>::try_from(&config.http_rpc_url)?;

    let epoch_finalized_topic = H256::from(ethers::utils::keccak256(
        "EpochFinalized(uint256,bytes32,uint256)",
    ));

    let mut last_block = provider.get_block_number().await?.as_u64();
    let interval = Duration::from_secs(config.poll_interval_secs);

    info!(
        "Polling {} EpochManager every {}s from block {}",
        config.name, config.poll_interval_secs, last_block
    );

    loop {
        sleep(interval).await;

        let current_block = match provider.get_block_number().await {
            Ok(b) => b.as_u64(),
            Err(e) => {
                warn!("Failed to get block number on {}: {}", config.name, e);
                continue;
            }
        };

        if current_block <= last_block {
            continue;
        }

        let filter = Filter::new()
            .address(config.epoch_manager_address.parse::<Address>().unwrap())
            .topic0(epoch_finalized_topic)
            .from_block(last_block + 1)
            .to_block(current_block);

        match provider.get_logs(&filter).await {
            Ok(logs) => {
                for log in logs {
                    if let Ok(event) = parse_epoch_finalized_log(&log, config) {
                        // Check confirmations
                        let log_block = log.block_number.unwrap_or_default().as_u64();
                        if current_block.saturating_sub(log_block) >= config.confirmation_blocks {
                            if let Err(e) = event_tx.send(event).await {
                                error!("Failed to send epoch event: {}", e);
                                return Ok(());
                            }
                        }
                    }
                }
            }
            Err(e) => {
                warn!("Failed to get logs on {}: {}", config.name, e);
            }
        }

        last_block = current_block;
    }
}

/// Parse an EpochFinalized log into an EpochEvent
fn parse_epoch_finalized_log(
    log: &ethers::types::Log,
    config: &ChainWatchConfig,
) -> Result<EpochEvent, String> {
    // EpochFinalized(uint256 epochId, bytes32 nullifierRoot, uint256 nullifierCount)
    // epochId is in topics[1], rest in data
    if log.topics.len() < 2 {
        return Err("Missing topics in EpochFinalized log".into());
    }

    let epoch_id = ethers::types::U256::from(log.topics[1].as_bytes()).as_u64();

    // Decode data: nullifierRoot (bytes32) + nullifierCount (uint256)
    if log.data.len() < 64 {
        return Err("Insufficient data in EpochFinalized log".into());
    }

    let mut nullifier_root = [0u8; 32];
    nullifier_root.copy_from_slice(&log.data[0..32]);

    let nullifier_count = ethers::types::U256::from(&log.data[32..64]).as_u32();

    let block_number = log.block_number.unwrap_or_default().as_u64();
    let tx_hash = log
        .transaction_hash
        .map(|h| format!("0x{}", hex::encode(h.as_bytes())))
        .unwrap_or_default();

    Ok(EpochEvent {
        chain_id: config.chain_id,
        chain_name: config.name.clone(),
        epoch_id,
        nullifier_root,
        nullifier_count,
        block_number,
        tx_hash,
        timestamp: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    })
}

/// Wait for N block confirmations
async fn wait_for_confirmations<P: ethers::providers::Middleware>(
    provider: &P,
    target_block: u64,
    confirmations: u64,
) {
    loop {
        match provider.get_block_number().await {
            Ok(current) => {
                if current.as_u64() >= target_block + confirmations {
                    return;
                }
            }
            Err(_) => {}
        }
        sleep(Duration::from_secs(2)).await;
    }
}
