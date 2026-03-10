//! Proof submitter module — sends verified proofs to on-chain privacy pools.
//!
//! Supports EVM chains (via ethers-rs) and Substrate parachains (via subxt).

use crate::types::*;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum SubmitError {
    #[error("Transaction reverted: {0}")]
    Reverted(String),
    #[error("RPC error: {0}")]
    RpcError(String),
    #[error("Signing failed: {0}")]
    SigningFailed(String),
    #[error("Unsupported chain: {0:?}")]
    UnsupportedChain(TargetChain),
    #[error("Proof format error: {0}")]
    ProofFormatError(String),
}

/// Multi-chain proof submitter
pub struct ProofSubmitter {
    configs: Vec<(TargetChain, ChainConfig)>,
}

impl ProofSubmitter {
    pub fn new(configs: Vec<(TargetChain, ChainConfig)>) -> Self {
        Self { configs }
    }

    /// Submit a transfer proof to the target chain's privacy pool.
    pub async fn submit_transfer(
        &self,
        chain: &TargetChain,
        proof: &GeneratedProof,
        merkle_root: [u8; 32],
        nullifiers: [[u8; 32]; 2],
        output_commitments: [[u8; 32]; 2],
    ) -> Result<SubmissionResult, SubmitError> {
        let config = self.get_config(chain)?;
        match chain.ecosystem() {
            Ecosystem::Avalanche | Ecosystem::Polkadot | Ecosystem::Cosmos | Ecosystem::Near => {
                // All current targets are EVM-compatible
                self.submit_evm_transfer(
                    config,
                    proof,
                    merkle_root,
                    nullifiers,
                    output_commitments,
                )
                .await
            }
        }
    }

    /// Submit a withdrawal proof to the target chain's privacy pool.
    pub async fn submit_withdraw(
        &self,
        chain: &TargetChain,
        proof: &GeneratedProof,
        merkle_root: [u8; 32],
        nullifiers: [[u8; 32]; 2],
        output_commitments: [[u8; 32]; 2],
        recipient: &str,
        exit_value: u128,
    ) -> Result<SubmissionResult, SubmitError> {
        let config = self.get_config(chain)?;
        self.submit_evm_withdraw(
            config,
            proof,
            merkle_root,
            nullifiers,
            output_commitments,
            recipient,
            exit_value,
        )
        .await
    }

    // ── EVM Submission ─────────────────────────────────────────

    async fn submit_evm_transfer(
        &self,
        config: &ChainConfig,
        proof: &GeneratedProof,
        merkle_root: [u8; 32],
        nullifiers: [[u8; 32]; 2],
        output_commitments: [[u8; 32]; 2],
    ) -> Result<SubmissionResult, SubmitError> {
        use ethers::prelude::*;
        use ethers::utils::hex;
        use std::sync::Arc;

        // Connect to RPC
        let provider = Provider::<Http>::try_from(&config.rpc_url)
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        let wallet: LocalWallet = config
            .signer_key
            .parse()
            .map_err(|e: WalletError| SubmitError::SigningFailed(e.to_string()))?;
        let chain_id = provider
            .get_chainid()
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;
        let wallet = wallet.with_chain_id(chain_id.as_u64());
        let client = Arc::new(SignerMiddleware::new(provider, wallet));

        // Encode function call: transfer(bytes,bytes32,bytes32[2],bytes32[2])
        let pool_address: Address = config
            .contracts
            .privacy_pool
            .parse()
            .map_err(|_| SubmitError::ProofFormatError("Invalid pool address".into()))?;

        // Use the SNARK wrapper proof for EVM, or raw if no wrapper
        let proof_bytes = proof.snark_wrapper.as_ref().unwrap_or(&proof.raw_proof);

        // ABI-encode the transfer call
        let call_data = Self::encode_transfer_call(
            proof_bytes,
            &merkle_root,
            &nullifiers,
            &output_commitments,
        );

        let tx = TransactionRequest::new()
            .to(pool_address)
            .data(call_data)
            .gas(500_000u64);

        let pending_tx = client
            .send_transaction(tx, None)
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        let receipt = pending_tx
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        match receipt {
            Some(receipt) => Ok(SubmissionResult {
                tx_hash: format!("0x{}", hex::encode(receipt.transaction_hash.as_bytes())),
                block_number: receipt.block_number.map(|b| b.as_u64()),
                gas_used: receipt.gas_used.map(|g| g.as_u128()),
                success: receipt.status.map(|s| s.as_u64() == 1).unwrap_or(false),
            }),
            None => Err(SubmitError::RpcError("No receipt returned".into())),
        }
    }

    async fn submit_evm_withdraw(
        &self,
        config: &ChainConfig,
        proof: &GeneratedProof,
        merkle_root: [u8; 32],
        nullifiers: [[u8; 32]; 2],
        output_commitments: [[u8; 32]; 2],
        recipient: &str,
        exit_value: u128,
    ) -> Result<SubmissionResult, SubmitError> {
        use ethers::prelude::*;
        use ethers::utils::hex;
        use std::sync::Arc;

        let provider = Provider::<Http>::try_from(&config.rpc_url)
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        let wallet: LocalWallet = config
            .signer_key
            .parse()
            .map_err(|e: WalletError| SubmitError::SigningFailed(e.to_string()))?;
        let chain_id = provider
            .get_chainid()
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;
        let wallet = wallet.with_chain_id(chain_id.as_u64());
        let client = Arc::new(SignerMiddleware::new(provider, wallet));

        let pool_address: Address = config
            .contracts
            .privacy_pool
            .parse()
            .map_err(|_| SubmitError::ProofFormatError("Invalid pool address".into()))?;

        let proof_bytes = proof.snark_wrapper.as_ref().unwrap_or(&proof.raw_proof);
        let recipient_addr: Address = recipient
            .parse()
            .map_err(|_| SubmitError::ProofFormatError("Invalid recipient address".into()))?;

        let call_data = Self::encode_withdraw_call(
            proof_bytes,
            &merkle_root,
            &nullifiers,
            &output_commitments,
            recipient_addr,
            exit_value,
        );

        let tx = TransactionRequest::new()
            .to(pool_address)
            .data(call_data)
            .gas(600_000u64);

        let pending_tx = client
            .send_transaction(tx, None)
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        let receipt = pending_tx
            .await
            .map_err(|e| SubmitError::RpcError(e.to_string()))?;

        match receipt {
            Some(receipt) => Ok(SubmissionResult {
                tx_hash: format!("0x{}", hex::encode(receipt.transaction_hash.as_bytes())),
                block_number: receipt.block_number.map(|b| b.as_u64()),
                gas_used: receipt.gas_used.map(|g| g.as_u128()),
                success: receipt.status.map(|s| s.as_u64() == 1).unwrap_or(false),
            }),
            None => Err(SubmitError::RpcError("No receipt returned".into())),
        }
    }

    // ── ABI Encoding ───────────────────────────────────────────

    fn encode_transfer_call(
        proof: &[u8],
        merkle_root: &[u8; 32],
        nullifiers: &[[u8; 32]; 2],
        output_commitments: &[[u8; 32]; 2],
    ) -> Vec<u8> {
        // transfer(bytes proof, bytes32 root, bytes32[2] nullifiers, bytes32[2] outputs)
        let sig_hash = ethers::utils::keccak256(b"transfer(bytes,bytes32,bytes32[2],bytes32[2])");
        let selector: [u8; 4] = [sig_hash[0], sig_hash[1], sig_hash[2], sig_hash[3]];

        let mut data = Vec::with_capacity(4 + 32 * 8 + proof.len());
        data.extend_from_slice(&selector);

        // Offset to proof bytes (dynamic)
        let offset = 32 * 5; // after root + 2 nullifiers + 2 outputs
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Uint(
            offset.into(),
        )]));

        // Merkle root
        data.extend_from_slice(merkle_root);

        // Nullifiers
        data.extend_from_slice(&nullifiers[0]);
        data.extend_from_slice(&nullifiers[1]);

        // Output commitments
        data.extend_from_slice(&output_commitments[0]);
        data.extend_from_slice(&output_commitments[1]);

        // Proof bytes (length-prefixed)
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Bytes(
            proof.to_vec(),
        )]));

        data
    }

    fn encode_withdraw_call(
        proof: &[u8],
        merkle_root: &[u8; 32],
        nullifiers: &[[u8; 32]; 2],
        output_commitments: &[[u8; 32]; 2],
        recipient: ethers::types::Address,
        exit_value: u128,
    ) -> Vec<u8> {
        let sig_hash = ethers::utils::keccak256(
            b"withdraw(bytes,bytes32,bytes32[2],bytes32[2],address,uint256)",
        );
        let selector: [u8; 4] = [sig_hash[0], sig_hash[1], sig_hash[2], sig_hash[3]];

        let mut data = Vec::with_capacity(4 + 32 * 10 + proof.len());
        data.extend_from_slice(&selector);

        let offset = 32 * 7;
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Uint(
            offset.into(),
        )]));

        data.extend_from_slice(merkle_root);
        data.extend_from_slice(&nullifiers[0]);
        data.extend_from_slice(&nullifiers[1]);
        data.extend_from_slice(&output_commitments[0]);
        data.extend_from_slice(&output_commitments[1]);

        // Recipient
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Address(
            recipient,
        )]));

        // Exit value
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Uint(
            exit_value.into(),
        )]));

        // Proof bytes
        data.extend_from_slice(&ethers::abi::encode(&[ethers::abi::Token::Bytes(
            proof.to_vec(),
        )]));

        data
    }

    // ── Helpers ────────────────────────────────────────────────

    fn get_config(&self, chain: &TargetChain) -> Result<&ChainConfig, SubmitError> {
        self.configs
            .iter()
            .find(|(c, _)| c == chain)
            .map(|(_, cfg)| cfg)
            .ok_or_else(|| SubmitError::UnsupportedChain(chain.clone()))
    }
}
