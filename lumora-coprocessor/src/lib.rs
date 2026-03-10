//! # Lumora Coprocessor
//!
//! Off-chain proof generation and multi-chain submission service.
//! This crate bridges Lumora's Halo2 proof engine with on-chain privacy
//! pools on EVM chains and Substrate parachains.
//!
//! ## Architecture
//!
//! ```text
//! ┌─────────────────┐     ┌──────────────┐     ┌────────────────┐
//! │  Client (SDK)   │────▸│  Coprocessor │────▸│  On-Chain Pool │
//! │  Prepares note  │     │  1. Generate │     │  PrivacyPool   │
//! │  commitment     │     │     proof    │     │  EpochManager  │
//! └─────────────────┘     │  2. Wrap for │     └────────────────┘
//!                         │     target   │
//!                         │  3. Submit   │
//!                         └──────────────┘
//! ```

pub mod chains;
pub mod circuits;
pub mod proof;
pub mod submitter;
pub mod types;

pub use types::*;
