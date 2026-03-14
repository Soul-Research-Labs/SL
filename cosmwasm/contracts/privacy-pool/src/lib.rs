//! # CosmWasm Privacy Pool
//!
//! A CosmWasm smart contract implementing a ZK privacy pool for Cosmos-based
//! chains. This is the CosmWasm port of the EVM PrivacyPool contract, using
//! Lumora's cryptographic primitives.
//!
//! ## Supported Chains
//! - Evmos (via CosmWasm module)
//! - Osmosis (via CosmWasm)
//! - Any Cosmos chain with CosmWasm support
//!
//! ## IBC Integration
//! Epoch nullifier roots can be synced across Cosmos chains via IBC packets,
//! enabling cross-chain nullifier deduplication.

pub mod contract;
pub mod error;
pub mod msg;
pub mod poseidon;
pub mod state;

pub use crate::error::ContractError;
