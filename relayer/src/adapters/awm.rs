//! Avalanche Warp Messaging (AWM) bridge adapter.
//!
//! Relays epoch roots between Avalanche C-Chain and Subnets using the
//! native AWM protocol (ICM-level messaging).

use async_trait::async_trait;
use super::{AdapterError, BridgeAdapter, EpochRootMessage};
use crate::config::ChainWatchConfig;

/// Avalanche subnet chain IDs (C-Chain mainnet + Fuji testnet).
const AVALANCHE_MAINNET: u64 = 43114;
const AVALANCHE_FUJI: u64 = 43113;

pub struct AwmAdapter;

impl AwmAdapter {
    pub fn new() -> Self {
        Self
    }

    fn is_avalanche(chain_id: u64) -> bool {
        chain_id == AVALANCHE_MAINNET || chain_id == AVALANCHE_FUJI
    }
}

#[async_trait]
impl BridgeAdapter for AwmAdapter {
    fn protocol_name(&self) -> &str {
        "Avalanche Warp Messaging"
    }

    fn supports_chain(&self, chain_id: u64) -> bool {
        Self::is_avalanche(chain_id)
    }

    async fn send_epoch_root(
        &self,
        target_chain: &ChainWatchConfig,
        message: &EpochRootMessage,
    ) -> Result<String, AdapterError> {
        if !self.supports_chain(target_chain.chain_id) {
            return Err(AdapterError::UnsupportedChain(target_chain.chain_id));
        }

        // Encode the AWM message: receiveRemoteEpochRoot(uint256,uint256,bytes32)
        let bridge_addr = target_chain
            .bridge_adapter_address
            .as_deref()
            .ok_or_else(|| AdapterError::Bridge("no bridge adapter address configured".into()))?;

        let calldata = encode_receive_remote_root(
            message.source_chain_id,
            message.epoch_id,
            &message.nullifier_root,
        );

        tracing::info!(
            protocol = "AWM",
            target_chain = target_chain.chain_id,
            epoch_id = message.epoch_id,
            "sending epoch root via AWM"
        );

        // Submit via EVM RPC
        let tx_hash = send_evm_transaction(
            &target_chain.http_rpc_url,
            &target_chain.signer_key,
            bridge_addr,
            &calldata,
        )
        .await?;

        Ok(tx_hash)
    }

    async fn estimate_fee(
        &self,
        _target_chain: &ChainWatchConfig,
    ) -> Result<u128, AdapterError> {
        // AWM messages are included in subnet consensus — no bridge fee,
        // only gas cost (~200K gas × gas price)
        Ok(0)
    }
}

/// ABI-encode `receiveRemoteEpochRoot(uint256,uint256,bytes32)`.
fn encode_receive_remote_root(
    source_chain_id: u64,
    epoch_id: u64,
    nullifier_root: &[u8; 32],
) -> Vec<u8> {
    // Function selector: keccak256("receiveRemoteEpochRoot(uint256,uint256,bytes32)")[..4]
    let selector: [u8; 4] = [0x8b, 0x7e, 0x43, 0x11]; // placeholder — compute at build

    let mut data = Vec::with_capacity(4 + 96);
    data.extend_from_slice(&selector);

    // source_chain_id as uint256
    let mut buf = [0u8; 32];
    buf[24..].copy_from_slice(&source_chain_id.to_be_bytes());
    data.extend_from_slice(&buf);

    // epoch_id as uint256
    let mut buf = [0u8; 32];
    buf[24..].copy_from_slice(&epoch_id.to_be_bytes());
    data.extend_from_slice(&buf);

    // nullifier_root as bytes32
    data.extend_from_slice(nullifier_root);

    data
}

/// Submit an EVM transaction via JSON-RPC.
async fn send_evm_transaction(
    rpc_url: &str,
    signer_key: &str,
    to: &str,
    calldata: &[u8],
) -> Result<String, AdapterError> {
    use ethers::prelude::*;

    let provider = Provider::<Http>::try_from(rpc_url)
        .map_err(|e| AdapterError::Rpc(e.to_string()))?;

    let wallet: LocalWallet = signer_key
        .parse()
        .map_err(|e: WalletError| AdapterError::Signing(e.to_string()))?;

    let client = SignerMiddleware::new(provider, wallet);

    let to_addr: Address = to
        .parse()
        .map_err(|_| AdapterError::Bridge(format!("invalid address: {}", to)))?;

    let tx = TransactionRequest::new()
        .to(to_addr)
        .data(calldata.to_vec())
        .gas(300_000u64);

    let pending = client
        .send_transaction(tx, None)
        .await
        .map_err(|e| AdapterError::Rpc(e.to_string()))?;

    let receipt = pending
        .await
        .map_err(|e| AdapterError::Rpc(e.to_string()))?
        .ok_or_else(|| AdapterError::Rpc("no receipt".into()))?;

    Ok(format!("{:?}", receipt.transaction_hash))
}
