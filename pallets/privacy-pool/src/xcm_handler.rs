//! XCM handler for cross-parachain privacy operations.
//!
//! This module handles incoming and outgoing XCM messages for:
//! 1. Epoch nullifier root synchronization between parachains
//! 2. Cross-chain shielded transfer initiation
//! 3. Global nullifier registry updates
//!
//! ## Message Types
//!
//! - `SyncEpochRoot(para_id, epoch_id, root)` — Broadcast finalized epoch root
//! - `VerifyNullifier(para_id, nullifier)` — Check if nullifier is spent remotely
//! - `NullifierStatus(para_id, nullifier, spent)` — Response to verification query
//!
//! ## Usage
//!
//! In your runtime, configure the XCM executor to route privacy-related XCM
//! messages (identified by `PrivacyXcmMessage` encoding) to this handler.
//!
//! ```ignore
//! // In runtime xcm_config.rs:
//! impl xcm_executor::Config for XcmConfig {
//!     type MessageSender = PrivacyXcmSender<Runtime>;
//!     // ...
//! }
//! ```

use parity_scale_codec::{Decode, Encode};
use scale_info::TypeInfo;
use sp_core::H256;
use sp_std::vec::Vec;

/// XCM message types for privacy operations
#[derive(Clone, Encode, Decode, TypeInfo, Debug, PartialEq)]
pub enum PrivacyXcmMessage {
    /// Broadcast a finalized epoch's nullifier root to peer parachains
    SyncEpochRoot {
        /// Source parachain ID
        source_para_id: u32,
        /// Epoch identifier
        epoch_id: u64,
        /// Merkle root of all nullifiers in this epoch
        nullifier_root: H256,
        /// Number of nullifiers in this epoch
        nullifier_count: u32,
    },

    /// Query whether a nullifier has been spent on a remote parachain
    VerifyNullifier {
        /// Requesting parachain ID
        requester_para_id: u32,
        /// The nullifier to check
        nullifier: H256,
        /// Nonce for correlating request/response
        request_nonce: u64,
    },

    /// Response to a nullifier verification query
    NullifierStatus {
        /// The parachain that checked the nullifier
        responder_para_id: u32,
        /// The queried nullifier
        nullifier: H256,
        /// Whether it's been spent
        spent: bool,
        /// Correlation nonce from the request
        request_nonce: u64,
    },

    /// Register this parachain's privacy pool in the universal registry
    RegisterChain {
        /// Parachain ID being registered
        para_id: u32,
        /// Application ID
        app_id: u32,
        /// Pool configuration hash (for verification)
        config_hash: H256,
    },
}

impl PrivacyXcmMessage {
    /// Encode the message for XCM Transact payload
    pub fn encode_for_xcm(&self) -> Vec<u8> {
        // Prefix with a magic byte to identify privacy XCM messages
        let mut encoded = Vec::with_capacity(128);
        encoded.push(0x50); // 'P' (0x50) for privacy
        encoded.extend_from_slice(&self.encode());
        encoded
    }

    /// Decode from XCM Transact payload
    pub fn decode_from_xcm(data: &[u8]) -> Option<Self> {
        if data.is_empty() || data[0] != 0x50 {
            return None;
        }
        Self::decode(&mut &data[1..]).ok()
    }
}

/// XCM sender for privacy messages.
///
/// Responsible for constructing and dispatching XCM messages to peer
/// parachains when epoch roots are finalized.
pub struct PrivacyXcmSender;

impl PrivacyXcmSender {
    /// Build an XCM Transact message to sync epoch root to a target parachain
    ///
    /// # Arguments
    /// * `target_para_id` — Destination parachain ID
    /// * `source_para_id` — This parachain's ID
    /// * `epoch_id` — The finalized epoch
    /// * `nullifier_root` — Epoch's nullifier Merkle root
    /// * `nullifier_count` — Number of nullifiers in the epoch
    ///
    /// # Returns
    /// Encoded XCM message bytes ready for dispatch
    pub fn build_sync_epoch_root_xcm(
        target_para_id: u32,
        source_para_id: u32,
        epoch_id: u64,
        nullifier_root: H256,
        nullifier_count: u32,
    ) -> Vec<u8> {
        let msg = PrivacyXcmMessage::SyncEpochRoot {
            source_para_id,
            epoch_id,
            nullifier_root,
            nullifier_count,
        };
        msg.encode_for_xcm()
    }

    /// Build an XCM query to check a nullifier on another parachain
    pub fn build_verify_nullifier_xcm(
        requester_para_id: u32,
        nullifier: H256,
        nonce: u64,
    ) -> Vec<u8> {
        let msg = PrivacyXcmMessage::VerifyNullifier {
            requester_para_id,
            nullifier,
            request_nonce: nonce,
        };
        msg.encode_for_xcm()
    }
}

/// XCM receiver — processes incoming privacy XCM messages.
///
/// This should be integrated as a callback in the pallet's XCM handler
/// (e.g., triggered by `pallet_xcm::Pallet` or a custom XCM barrier).
pub struct PrivacyXcmReceiver;

impl PrivacyXcmReceiver {
    /// Process an incoming privacy XCM message.
    ///
    /// Returns the decoded message and any response action needed.
    pub fn process_incoming(data: &[u8]) -> Option<PrivacyXcmAction> {
        let msg = PrivacyXcmMessage::decode_from_xcm(data)?;

        match msg {
            PrivacyXcmMessage::SyncEpochRoot {
                source_para_id,
                epoch_id,
                nullifier_root,
                nullifier_count,
            } => Some(PrivacyXcmAction::StoreRemoteEpochRoot {
                source_para_id,
                epoch_id,
                nullifier_root,
                nullifier_count,
            }),

            PrivacyXcmMessage::VerifyNullifier {
                requester_para_id,
                nullifier,
                request_nonce,
            } => Some(PrivacyXcmAction::CheckNullifierAndRespond {
                requester_para_id,
                nullifier,
                request_nonce,
            }),

            PrivacyXcmMessage::NullifierStatus {
                responder_para_id,
                nullifier,
                spent,
                request_nonce,
            } => Some(PrivacyXcmAction::ProcessNullifierResponse {
                responder_para_id,
                nullifier,
                spent,
                request_nonce,
            }),

            PrivacyXcmMessage::RegisterChain {
                para_id,
                app_id,
                config_hash,
            } => Some(PrivacyXcmAction::RegisterRemoteChain {
                para_id,
                app_id,
                config_hash,
            }),
        }
    }
}

/// Actions the pallet should take in response to XCM messages
#[derive(Clone, Debug, PartialEq)]
pub enum PrivacyXcmAction {
    /// Store a remote epoch root received from another parachain
    StoreRemoteEpochRoot {
        source_para_id: u32,
        epoch_id: u64,
        nullifier_root: H256,
        nullifier_count: u32,
    },

    /// Check if a nullifier is spent locally and send response
    CheckNullifierAndRespond {
        requester_para_id: u32,
        nullifier: H256,
        request_nonce: u64,
    },

    /// Process a nullifier status response from another parachain
    ProcessNullifierResponse {
        responder_para_id: u32,
        nullifier: H256,
        spent: bool,
        request_nonce: u64,
    },

    /// Register a remote parachain's privacy pool
    RegisterRemoteChain {
        para_id: u32,
        app_id: u32,
        config_hash: H256,
    },
}

/// Destination parachain IDs for epoch root broadcasting.
///
/// When a local epoch is finalized, roots should be sent to all
/// known privacy-enabled parachains for cross-chain nullifier dedup.
#[derive(Clone, Encode, Decode, TypeInfo, Debug, PartialEq)]
pub struct BroadcastConfig {
    /// List of parachain IDs to send epoch roots to
    pub target_parachains: Vec<u32>,
    /// Whether to also send to the relay chain (Polkadot/Kusama)
    pub include_relay_chain: bool,
}

impl Default for BroadcastConfig {
    fn default() -> Self {
        Self {
            target_parachains: Vec::new(),
            include_relay_chain: false,
        }
    }
}
