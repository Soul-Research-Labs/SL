//! Type definitions for the Privacy Pool pallet.

use parity_scale_codec::{Decode, Encode, MaxEncodedLen};
use scale_info::TypeInfo;
use sp_core::H256;

/// Information about an epoch
#[derive(Clone, Encode, Decode, TypeInfo, MaxEncodedLen, Debug, PartialEq)]
pub struct EpochInfo<BlockNumber> {
    /// Block at which this epoch started
    pub start_block: BlockNumber,
    /// Block at which this epoch was finalized (None if still active)
    pub end_block: Option<BlockNumber>,
    /// Merkle root of all nullifiers in this epoch
    pub nullifier_root: H256,
    /// Number of nullifiers in this epoch
    pub nullifier_count: u32,
    /// Whether this epoch has been finalized
    pub finalized: bool,
}

/// Public inputs for the transfer circuit
#[derive(Clone, Debug)]
pub struct TransferPublicInputs {
    pub merkle_root: H256,
    pub nullifiers: [H256; 2],
    pub output_commitments: [H256; 2],
    pub domain_chain_id: u32,
    pub domain_app_id: u32,
}

/// Public inputs for the withdraw circuit
#[derive(Clone, Debug)]
pub struct WithdrawPublicInputs {
    pub merkle_root: H256,
    pub nullifiers: [H256; 2],
    pub output_commitments: [H256; 2],
    pub exit_value: u128,
}

/// Note commitment structure (matches Lumora's lumora-note)
#[derive(Clone, Encode, Decode, TypeInfo, MaxEncodedLen, Debug, PartialEq)]
pub struct NoteCommitment {
    /// Poseidon commitment value
    pub commitment: H256,
    /// Asset ID (0 for native token)
    pub asset_id: u32,
}

/// Domain separation tag for V2 nullifiers
#[derive(Clone, Encode, Decode, TypeInfo, MaxEncodedLen, Debug, PartialEq)]
pub struct DomainTag {
    /// Parachain ID (for Polkadot) or chain ID (for EVM)
    pub chain_id: u32,
    /// Application ID
    pub app_id: u32,
}
