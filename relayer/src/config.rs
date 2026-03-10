use serde::{Deserialize, Serialize};

/// Relayer daemon configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RelayerConfig {
    /// Chain configurations to monitor
    pub chains: Vec<ChainWatchConfig>,

    /// Universal Nullifier Registry address (hub chain)
    pub registry: RegistryConfig,

    /// Metadata resistance settings
    pub metadata_resistance: MetadataResistanceConfig,

    /// HTTP server port for health/metrics endpoints
    pub metrics_port: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChainWatchConfig {
    /// Chain ID
    pub chain_id: u64,
    /// Human-readable name
    pub name: String,
    /// WebSocket RPC URL (for event subscription)
    pub ws_rpc_url: String,
    /// HTTP RPC URL (for transactions)
    pub http_rpc_url: String,
    /// EpochManager contract address
    pub epoch_manager_address: String,
    /// PrivacyPool contract address
    pub privacy_pool_address: String,
    /// Bridge adapter address (for sending cross-chain messages)
    pub bridge_adapter_address: Option<String>,
    /// Signer private key (hex-encoded)
    pub signer_key: String,
    /// Poll interval in seconds (fallback if WS unavailable)
    pub poll_interval_secs: u64,
    /// Number of confirmations before relaying
    pub confirmation_blocks: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RegistryConfig {
    /// Chain ID where the universal registry is deployed
    pub chain_id: u64,
    /// Contract address
    pub address: String,
    /// RPC URL
    pub rpc_url: String,
    /// Signer key
    pub signer_key: String,
}

/// Metadata resistance configuration to prevent traffic analysis
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MetadataResistanceConfig {
    /// Enable random timing jitter on relay messages
    pub jitter_enabled: bool,
    /// Maximum jitter in milliseconds (uniform random [0, max])
    pub max_jitter_ms: u64,
    /// Enable batching: accumulate events before relaying
    pub batching_enabled: bool,
    /// Maximum events to batch before flushing
    pub batch_size: usize,
    /// Maximum time to hold a batch (ms) before flushing
    pub batch_timeout_ms: u64,
    /// Enable dummy message padding (send fake relays to mask real ones)
    pub dummy_padding_enabled: bool,
    /// Target messages per minute (real + dummy)
    pub target_messages_per_minute: u32,
}

impl Default for MetadataResistanceConfig {
    fn default() -> Self {
        Self {
            jitter_enabled: true,
            max_jitter_ms: 5000,
            batching_enabled: true,
            batch_size: 10,
            batch_timeout_ms: 30000,
            dummy_padding_enabled: false, // conservative default
            target_messages_per_minute: 0,
        }
    }
}

impl Default for RelayerConfig {
    fn default() -> Self {
        Self {
            chains: vec![],
            registry: RegistryConfig {
                chain_id: 43113,
                address: String::new(),
                rpc_url: String::new(),
                signer_key: String::new(),
            },
            metadata_resistance: MetadataResistanceConfig::default(),
            metrics_port: 9090,
        }
    }
}
