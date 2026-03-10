//! Chain-specific configuration and RPC management.

use crate::types::*;
use std::collections::HashMap;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ChainError {
    #[error("Chain not configured: {0:?}")]
    NotConfigured(TargetChain),
    #[error("RPC connection failed: {0}")]
    RpcFailed(String),
}

/// Registry of chain configurations and RPC endpoints
pub struct ChainRegistry {
    configs: HashMap<TargetChain, ChainConfig>,
}

impl ChainRegistry {
    pub fn new() -> Self {
        Self {
            configs: HashMap::new(),
        }
    }

    pub fn from_config(config: &CoprocessorConfig) -> Self {
        let configs = config
            .chains
            .iter()
            .cloned()
            .collect::<HashMap<_, _>>();
        Self { configs }
    }

    pub fn register(&mut self, chain: TargetChain, config: ChainConfig) {
        self.configs.insert(chain, config);
    }

    pub fn get(&self, chain: &TargetChain) -> Result<&ChainConfig, ChainError> {
        self.configs
            .get(chain)
            .ok_or_else(|| ChainError::NotConfigured(chain.clone()))
    }

    pub fn supported_chains(&self) -> Vec<&TargetChain> {
        self.configs.keys().collect()
    }
}

/// Default RPC endpoints for testnets
pub fn default_testnet_rpcs() -> Vec<(TargetChain, &'static str)> {
    vec![
        (TargetChain::AvalancheFuji, "https://api.avax-test.network/ext/bc/C/rpc"),
        (TargetChain::MoonbaseAlpha, "https://rpc.api.moonbase.moonbeam.network"),
        (TargetChain::AstarShibuya, "https://evm.shibuya.astar.network"),
        (TargetChain::EvmosTestnet, "https://eth.bd.evmos.dev:8545"),
        (TargetChain::AuroraTestnet, "https://testnet.aurora.dev"),
    ]
}
