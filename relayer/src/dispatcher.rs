//! Relay dispatcher — executes on-chain transactions for relay commands.
//!
//! Takes `RelayCommand` values from the aggregator and submits the corresponding
//! transactions to peer chains' EpochManagers (for cross-chain root sync) or
//! to the Universal Nullifier Registry hub.

use crate::config::{ChainWatchConfig, RegistryConfig, RelayerConfig};
use crate::metrics::Metrics;
use crate::RelayCommand;
use std::sync::Arc;
use thiserror::Error;
use tracing::{error, info, warn};

#[derive(Error, Debug)]
pub enum DispatchError {
    #[error("RPC error: {0}")]
    Rpc(String),
    #[error("Signing error: {0}")]
    Signing(String),
    #[error("Transaction reverted: {0}")]
    Reverted(String),
    #[error("Unknown target chain: {0}")]
    UnknownChain(u64),
    #[error("No bridge adapter configured for chain: {0}")]
    NoBridgeAdapter(u64),
}

/// Dispatcher that sends relay transactions on-chain.
pub struct Dispatcher {
    config: Arc<RelayerConfig>,
    metrics: Arc<Metrics>,
}

impl Dispatcher {
    pub fn new(config: Arc<RelayerConfig>, metrics: Arc<Metrics>) -> Self {
        Self { config, metrics }
    }

    /// Dispatch a single relay command.
    pub async fn dispatch(&self, cmd: RelayCommand) -> Result<(), DispatchError> {
        match cmd {
            RelayCommand::SendToChain {
                target_chain_id,
                source_chain_id,
                epoch_id,
                nullifier_root,
            } => {
                self.send_to_chain(target_chain_id, source_chain_id, epoch_id, nullifier_root)
                    .await
            }
            RelayCommand::SubmitToRegistry {
                source_chain_id,
                epoch_id,
                nullifier_root,
                nullifier_count,
            } => {
                self.submit_to_registry(source_chain_id, epoch_id, nullifier_root, nullifier_count)
                    .await
            }
        }
    }

    /// Relay an epoch root from one chain to a peer chain's EpochManager via bridge adapter.
    async fn send_to_chain(
        &self,
        target_chain_id: u64,
        source_chain_id: u64,
        epoch_id: u64,
        nullifier_root: [u8; 32],
    ) -> Result<(), DispatchError> {
        let chain_cfg = self
            .find_chain(target_chain_id)
            .ok_or(DispatchError::UnknownChain(target_chain_id))?;

        let bridge_addr = chain_cfg
            .bridge_adapter_address
            .as_ref()
            .ok_or(DispatchError::NoBridgeAdapter(target_chain_id))?;

        info!(
            target_chain = target_chain_id,
            source_chain = source_chain_id,
            epoch = epoch_id,
            "Dispatching epoch root to peer chain via bridge adapter"
        );

        // Build calldata for BridgeAdapter.sendMessage(targetChainId, epochManager, payload, gasLimit)
        // The payload encodes: receiveRemoteRoot(sourceChainId, epochId, root)
        let payload = encode_receive_remote_root(source_chain_id, epoch_id, &nullifier_root);

        let calldata = encode_send_message(
            source_chain_id, // destination perspective: we send from source
            &chain_cfg.epoch_manager_address,
            &payload,
            200_000, // gas limit for remote execution
        );

        let tx_hash = self
            .send_evm_tx(
                &chain_cfg.http_rpc_url,
                &chain_cfg.signer_key,
                bridge_addr,
                &calldata,
                0, // no value
            )
            .await?;

        info!(
            tx_hash = %tx_hash,
            target_chain = target_chain_id,
            epoch = epoch_id,
            "Bridge relay transaction submitted"
        );

        self.metrics.inc_relays_dispatched();
        Ok(())
    }

    /// Submit an epoch root to the Universal Nullifier Registry on the hub chain.
    async fn submit_to_registry(
        &self,
        source_chain_id: u64,
        epoch_id: u64,
        nullifier_root: [u8; 32],
        nullifier_count: u32,
    ) -> Result<(), DispatchError> {
        let reg = &self.config.registry;

        info!(
            source_chain = source_chain_id,
            epoch = epoch_id,
            nullifier_count = nullifier_count,
            "Submitting epoch root to universal registry"
        );

        // submitEpochRoot(uint256 chainId, uint256 epochId, bytes32 root, uint32 nullifierCount)
        let calldata =
            encode_submit_epoch_root(source_chain_id, epoch_id, &nullifier_root, nullifier_count);

        let tx_hash = self
            .send_evm_tx(
                &reg.rpc_url,
                &reg.signer_key,
                &reg.address,
                &calldata,
                0,
            )
            .await?;

        info!(
            tx_hash = %tx_hash,
            source_chain = source_chain_id,
            epoch = epoch_id,
            "Registry submission transaction submitted"
        );

        self.metrics.inc_registry_submissions();
        Ok(())
    }

    /// Send an EVM transaction via ethers-rs.
    async fn send_evm_tx(
        &self,
        rpc_url: &str,
        signer_key: &str,
        to: &str,
        calldata: &[u8],
        value: u64,
    ) -> Result<String, DispatchError> {
        use ethers::prelude::*;
        use ethers::utils::hex;
        use std::sync::Arc as StdArc;

        let provider = Provider::<Http>::try_from(rpc_url)
            .map_err(|e| DispatchError::Rpc(e.to_string()))?;

        let wallet: LocalWallet = signer_key
            .parse()
            .map_err(|e: WalletError| DispatchError::Signing(e.to_string()))?;

        let chain_id = provider
            .get_chainid()
            .await
            .map_err(|e| DispatchError::Rpc(e.to_string()))?;

        let wallet = wallet.with_chain_id(chain_id.as_u64());
        let client = StdArc::new(SignerMiddleware::new(provider, wallet));

        let to_addr: Address = to
            .parse()
            .map_err(|_| DispatchError::Rpc(format!("Invalid address: {}", to)))?;

        let tx = TransactionRequest::new()
            .to(to_addr)
            .data(calldata.to_vec())
            .value(value);

        let pending = client
            .send_transaction(tx, None)
            .await
            .map_err(|e| DispatchError::Rpc(e.to_string()))?;

        let receipt = pending
            .await
            .map_err(|e| DispatchError::Rpc(e.to_string()))?;

        match receipt {
            Some(r) => {
                let success = r.status.map(|s| s.as_u64() == 1).unwrap_or(false);
                let hash = format!("0x{}", hex::encode(r.transaction_hash.as_bytes()));
                if !success {
                    return Err(DispatchError::Reverted(hash));
                }
                Ok(hash)
            }
            None => Err(DispatchError::Rpc("No receipt returned".into())),
        }
    }

    fn find_chain(&self, chain_id: u64) -> Option<&ChainWatchConfig> {
        self.config.chains.iter().find(|c| c.chain_id == chain_id)
    }
}

// ── ABI Encoding Helpers ───────────────────────────────────

/// Encode `receiveRemoteRoot(uint256 sourceChainId, uint256 epochId, bytes32 root)`
/// Selector: keccak256("receiveRemoteRoot(uint256,uint256,bytes32)")[:4]
fn encode_receive_remote_root(
    source_chain_id: u64,
    epoch_id: u64,
    root: &[u8; 32],
) -> Vec<u8> {
    // selector = 0x6a627842... compute at build time via ethers
    // For now we use the proper ABI encoding via ethers
    use ethers::abi::{encode, Token};

    let tokens = vec![
        Token::Uint(source_chain_id.into()),
        Token::Uint(epoch_id.into()),
        Token::FixedBytes(root.to_vec()),
    ];

    let mut data = Vec::with_capacity(4 + 32 * 3);
    // keccak256("receiveRemoteRoot(uint256,uint256,bytes32)") first 4 bytes
    let selector = ethers::utils::keccak256(b"receiveRemoteRoot(uint256,uint256,bytes32)");
    data.extend_from_slice(&selector[..4]);
    data.extend_from_slice(&encode(&tokens));
    data
}

/// Encode `sendMessage(uint256 destinationChainId, address recipient, bytes payload, uint256 gasLimit)`
fn encode_send_message(
    destination_chain_id: u64,
    recipient: &str,
    payload: &[u8],
    gas_limit: u64,
) -> Vec<u8> {
    use ethers::abi::{encode, Token};
    use ethers::types::Address;

    let recipient_addr: Address = recipient.parse().unwrap_or_default();

    let tokens = vec![
        Token::Uint(destination_chain_id.into()),
        Token::Address(recipient_addr),
        Token::Bytes(payload.to_vec()),
        Token::Uint(gas_limit.into()),
    ];

    let mut data = Vec::with_capacity(4 + 32 * 6);
    let selector =
        ethers::utils::keccak256(b"sendMessage(uint256,address,bytes,uint256)");
    data.extend_from_slice(&selector[..4]);
    data.extend_from_slice(&encode(&tokens));
    data
}

/// Encode `submitEpochRoot(uint256 chainId, uint256 epochId, bytes32 root, uint32 nullifierCount)`
fn encode_submit_epoch_root(
    chain_id: u64,
    epoch_id: u64,
    root: &[u8; 32],
    nullifier_count: u32,
) -> Vec<u8> {
    use ethers::abi::{encode, Token};

    let tokens = vec![
        Token::Uint(chain_id.into()),
        Token::Uint(epoch_id.into()),
        Token::FixedBytes(root.to_vec()),
        Token::Uint(nullifier_count.into()),
    ];

    let mut data = Vec::with_capacity(4 + 32 * 4);
    let selector =
        ethers::utils::keccak256(b"submitEpochRoot(uint256,uint256,bytes32,uint32)");
    data.extend_from_slice(&selector[..4]);
    data.extend_from_slice(&encode(&tokens));
    data
}
