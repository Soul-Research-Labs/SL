//! XCM (Cross-Consensus Messaging) bridge adapter.
//!
//! Relays epoch roots to Polkadot parachains (Moonbeam, Astar)
//! via XCM precompile calls on EVM-compatible parachains.

use async_trait::async_trait;
use super::{AdapterError, BridgeAdapter, EpochRootMessage};
use crate::config::ChainWatchConfig;

const MOONBEAM_MAINNET: u64 = 1284;
const MOONBASE_ALPHA: u64 = 1287;
const ASTAR_MAINNET: u64 = 592;
const ASTAR_SHIBUYA: u64 = 81;

/// Moonbeam XCM precompile at 0x0000000000000000000000000000000000000805
const XCM_PRECOMPILE: &str = "0x0000000000000000000000000000000000000805";

pub struct XcmAdapter;

impl XcmAdapter {
    pub fn new() -> Self {
        Self
    }

    fn is_polkadot_parachain(chain_id: u64) -> bool {
        matches!(
            chain_id,
            MOONBEAM_MAINNET | MOONBASE_ALPHA | ASTAR_MAINNET | ASTAR_SHIBUYA
        )
    }
}

#[async_trait]
impl BridgeAdapter for XcmAdapter {
    fn protocol_name(&self) -> &str {
        "XCM"
    }

    fn supports_chain(&self, chain_id: u64) -> bool {
        Self::is_polkadot_parachain(chain_id)
    }

    async fn send_epoch_root(
        &self,
        target_chain: &ChainWatchConfig,
        message: &EpochRootMessage,
    ) -> Result<String, AdapterError> {
        if !self.supports_chain(target_chain.chain_id) {
            return Err(AdapterError::UnsupportedChain(target_chain.chain_id));
        }

        // For EVM parachains, use the XCM precompile to route the call
        // to the destination parachain's privacy pool pallet
        let calldata = encode_xcm_transact(
            message.source_chain_id,
            message.epoch_id,
            &message.nullifier_root,
        );

        tracing::info!(
            protocol = "XCM",
            target_chain = target_chain.chain_id,
            epoch_id = message.epoch_id,
            "sending epoch root via XCM precompile"
        );

        let tx_hash = send_xcm_transaction(
            &target_chain.http_rpc_url,
            &target_chain.signer_key,
            XCM_PRECOMPILE,
            &calldata,
        )
        .await?;

        Ok(tx_hash)
    }

    async fn estimate_fee(
        &self,
        _target_chain: &ChainWatchConfig,
    ) -> Result<u128, AdapterError> {
        // XCM fees depend on destination weight; estimate ~0.01 GLMR/ASTR
        Ok(10_000_000_000_000_000) // 0.01 × 10^18
    }
}

/// Encode a transactThroughSigned XCM precompile call carrying the epoch root.
fn encode_xcm_transact(
    source_chain_id: u64,
    epoch_id: u64,
    nullifier_root: &[u8; 32],
) -> Vec<u8> {
    // Selector for transactThroughSigned(...)
    let selector: [u8; 4] = [0xb6, 0x48, 0xf3, 0x73]; // placeholder

    let mut data = Vec::with_capacity(4 + 128);
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

/// Submit an EVM transaction targeting the XCM precompile.
async fn send_xcm_transaction(
    rpc_url: &str,
    signer_key: &str,
    precompile: &str,
    calldata: &[u8],
) -> Result<String, AdapterError> {
    use ethers::prelude::*;

    let provider = Provider::<Http>::try_from(rpc_url)
        .map_err(|e| AdapterError::Rpc(e.to_string()))?;

    let wallet: LocalWallet = signer_key
        .parse()
        .map_err(|e: WalletError| AdapterError::Signing(e.to_string()))?;

    let client = SignerMiddleware::new(provider, wallet);

    let to_addr: Address = precompile
        .parse()
        .map_err(|_| AdapterError::Bridge(format!("invalid precompile address: {}", precompile)))?;

    let tx = TransactionRequest::new()
        .to(to_addr)
        .data(calldata.to_vec())
        .gas(500_000u64); // XCM transact uses more gas

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
