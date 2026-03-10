//! Core types for the Lumora coprocessor.

use serde::{Deserialize, Serialize};

/// Supported target chains
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub enum TargetChain {
    AvalancheFuji,
    AvalancheMainnet,
    MoonbaseAlpha,
    Moonbeam,
    AstarShibuya,
    Astar,
    EvmosTestnet,
    Evmos,
    AuroraTestnet,
    Aurora,
}

impl TargetChain {
    pub fn chain_id(&self) -> u64 {
        match self {
            Self::AvalancheFuji => 43113,
            Self::AvalancheMainnet => 43114,
            Self::MoonbaseAlpha => 1287,
            Self::Moonbeam => 1284,
            Self::AstarShibuya => 81,
            Self::Astar => 592,
            Self::EvmosTestnet => 9000,
            Self::Evmos => 9001,
            Self::AuroraTestnet => 1313161555,
            Self::Aurora => 1313161554,
        }
    }

    pub fn is_testnet(&self) -> bool {
        matches!(
            self,
            Self::AvalancheFuji
                | Self::MoonbaseAlpha
                | Self::AstarShibuya
                | Self::EvmosTestnet
                | Self::AuroraTestnet
        )
    }

    pub fn ecosystem(&self) -> Ecosystem {
        match self {
            Self::AvalancheFuji | Self::AvalancheMainnet => Ecosystem::Avalanche,
            Self::MoonbaseAlpha | Self::Moonbeam | Self::AstarShibuya | Self::Astar => {
                Ecosystem::Polkadot
            }
            Self::EvmosTestnet | Self::Evmos => Ecosystem::Cosmos,
            Self::AuroraTestnet | Self::Aurora => Ecosystem::Near,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Ecosystem {
    Avalanche,
    Polkadot,
    Cosmos,
    Near,
}

/// A generated ZK proof ready for submission
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GeneratedProof {
    /// Raw proof bytes (Halo2 IPA proof)
    pub raw_proof: Vec<u8>,
    /// SNARK wrapper proof (Groth16 for EVM, None for native)
    pub snark_wrapper: Option<Vec<u8>>,
    /// Public inputs
    pub public_inputs: Vec<[u8; 32]>,
    /// Proof type
    pub proof_type: ProofType,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum ProofType {
    Transfer,
    Withdraw,
    Aggregated,
}

/// Transfer proof request
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TransferRequest {
    /// Input note commitments
    pub input_notes: [[u8; 32]; 2],
    /// Spending keys for input notes
    pub spending_keys: [[u8; 32]; 2],
    /// Output note data
    pub output_notes: [OutputNote; 2],
    /// Merkle paths for input notes
    pub merkle_paths: [MerklePath; 2],
    /// Current Merkle root
    pub merkle_root: [u8; 32],
    /// Target chain for domain separation
    pub target_chain: TargetChain,
    /// Application ID for domain separation
    pub app_id: u32,
}

/// Withdraw proof request
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WithdrawRequest {
    /// Input note commitments
    pub input_notes: [[u8; 32]; 2],
    /// Spending keys for input notes
    pub spending_keys: [[u8; 32]; 2],
    /// Change output note
    pub change_note: OutputNote,
    /// Exit value (amount to withdraw)
    pub exit_value: u128,
    /// Merkle paths for input notes
    pub merkle_paths: [MerklePath; 2],
    /// Current Merkle root
    pub merkle_root: [u8; 32],
    /// Target chain
    pub target_chain: TargetChain,
    pub app_id: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputNote {
    /// Recipient's public key
    pub recipient_pk: [u8; 32],
    /// Value
    pub value: u128,
    /// Blinding factor
    pub blinding: [u8; 32],
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MerklePath {
    /// Sibling hashes from leaf to root
    pub siblings: Vec<[u8; 32]>,
    /// Path indices (0 = left, 1 = right)
    pub indices: Vec<u8>,
}

/// Result of an on-chain submission
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SubmissionResult {
    /// Transaction hash
    pub tx_hash: String,
    /// Block number where the tx was included
    pub block_number: Option<u64>,
    /// Gas used (EVM chains only)
    pub gas_used: Option<u128>,
    /// Whether submission was successful
    pub success: bool,
}

/// Chain-specific contract addresses
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChainContracts {
    pub privacy_pool: String,
    pub epoch_manager: String,
    pub bridge_adapter: Option<String>,
    pub verifier: Option<String>,
}

/// Coprocessor configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoprocessorConfig {
    /// Target chain configurations
    pub chains: Vec<(TargetChain, ChainConfig)>,
    /// Proof batching: max proofs per batch submission
    pub batch_size: usize,
    /// Proof batching: max wait time (ms) before submitting partial batch
    pub batch_timeout_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChainConfig {
    pub rpc_url: String,
    pub contracts: ChainContracts,
    /// Signer private key (hex-encoded, without 0x)
    pub signer_key: String,
}
