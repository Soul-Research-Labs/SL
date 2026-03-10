//! IBC (Inter-Blockchain Communication) bridge adapter.
//!
//! Relays epoch roots to Cosmos-ecosystem chains (Evmos) via IBC
//! packet submission through an EVM-side IBC precompile or relayer.

use async_trait::async_trait;
use super::{AdapterError, BridgeAdapter, EpochRootMessage};
use crate::config::ChainWatchConfig;

const EVMOS_MAINNET: u64 = 9001;
const EVMOS_TESTNET: u64 = 9000;

pub struct IbcAdapter;

impl IbcAdapter {
    pub fn new() -> Self {
        Self
    }

    fn is_cosmos_chain(chain_id: u64) -> bool {
        chain_id == EVMOS_MAINNET || chain_id == EVMOS_TESTNET
    }
}

#[async_trait]
impl BridgeAdapter for IbcAdapter {
    fn protocol_name(&self) -> &str {
        "IBC"
    }

    fn supports_chain(&self, chain_id: u64) -> bool {
        Self::is_cosmos_chain(chain_id)
    }

    async fn send_epoch_root(
        &self,
        target_chain: &ChainWatchConfig,
        message: &EpochRootMessage,
    ) -> Result<String, AdapterError> {
        if !self.supports_chain(target_chain.chain_id) {
            return Err(AdapterError::UnsupportedChain(target_chain.chain_id));
        }

        let bridge_addr = target_chain
            .bridge_adapter_address
            .as_deref()
            .ok_or_else(|| AdapterError::Bridge("no IBC gateway address configured".into()))?;

        let calldata = encode_ibc_send_packet(
            message.source_chain_id,
            message.epoch_id,
            &message.nullifier_root,
        );

        tracing::info!(
            protocol = "IBC",
            target_chain = target_chain.chain_id,
            epoch_id = message.epoch_id,
            "sending epoch root via IBC"
        );

        let tx_hash = send_ibc_transaction(
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
        // IBC relayer fee ~ 0.001 EVMOS
        Ok(1_000_000_000_000_000) // 0.001 × 10^18
    }
}

/// ABI-encode `sendIbcPacket(uint256,uint256,bytes32)` for the IBC gateway.
fn encode_ibc_send_packet(
    source_chain_id: u64,
    epoch_id: u64,
    nullifier_root: &[u8; 32],
) -> Vec<u8> {
    let selector: [u8; 4] = [0x8c, 0x87, 0xcb, 0xe6]; // keccak256("sendIbcPacket(uint256,uint256,bytes32)")[..4]

    let mut data = Vec::with_capacity(4 + 96);
    data.extend_from_slice(&selector);

    let mut buf = [0u8; 32];
    buf[24..].copy_from_slice(&source_chain_id.to_be_bytes());
    data.extend_from_slice(&buf);

    let mut buf = [0u8; 32];
    buf[24..].copy_from_slice(&epoch_id.to_be_bytes());
    data.extend_from_slice(&buf);

    data.extend_from_slice(nullifier_root);

    data
}

/// Submit an EVM transaction to the IBC gateway contract.
async fn send_ibc_transaction(
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
        .gas(400_000u64);

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
