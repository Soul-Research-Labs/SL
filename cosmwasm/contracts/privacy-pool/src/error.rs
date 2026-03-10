use cosmwasm_std::StdError;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ContractError {
    #[error("{0}")]
    Std(#[from] StdError),

    #[error("Unauthorized: only governance can perform this action")]
    Unauthorized {},

    #[error("Deposit amount must be non-zero")]
    ZeroDeposit {},

    #[error("Commitment already exists in the tree")]
    CommitmentAlreadyExists {},

    #[error("Merkle tree is full (reached maximum capacity)")]
    TreeFull {},

    #[error("Invalid ZK proof")]
    InvalidProof {},

    #[error("Nullifier has already been spent: {nullifier}")]
    NullifierAlreadySpent { nullifier: String },

    #[error("Merkle root is not in the known history")]
    UnknownMerkleRoot {},

    #[error("Insufficient pool balance for withdrawal")]
    InsufficientPoolBalance {},

    #[error("Withdrawal amount must be non-zero")]
    ZeroWithdrawal {},

    #[error("Epoch not ready for finalization")]
    EpochNotReady {},

    #[error("Epoch already finalized")]
    EpochAlreadyFinalized {},

    #[error("Too many nullifiers in current epoch")]
    EpochNullifierOverflow {},

    #[error("Invalid hex string: {0}")]
    InvalidHex(String),
}
