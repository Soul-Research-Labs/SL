"""Type definitions for the Soul Privacy SDK."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class ChainType(Enum):
    """Supported chain types."""
    EVM = "evm"
    SUBSTRATE = "substrate"
    COSMWASM = "cosmwasm"
    NEAR = "near"


@dataclass(frozen=True)
class ChainConfig:
    """Configuration for a single chain deployment."""
    chain_id: int
    rpc_url: str
    pool_address: str
    epoch_manager_address: str
    chain_type: ChainType = ChainType.EVM
    bridge_adapter_address: str | None = None
    registry_address: str | None = None


@dataclass(frozen=True)
class Note:
    """A shielded note in the privacy pool."""
    commitment: bytes
    value: int
    blinding: bytes
    owner_pubkey: bytes
    leaf_index: int | None = None
    spent: bool = False


@dataclass(frozen=True)
class NullifierInfo:
    """Nullifier metadata for a spent note."""
    nullifier: bytes
    chain_id: int
    app_id: int
    epoch_id: int | None = None


@dataclass(frozen=True)
class ProofRequest:
    """Off-chain proof generation request."""
    proof_type: str  # "transfer" or "withdraw"
    merkle_root: bytes
    input_notes: list[Note]
    spending_keys: list[bytes]
    merkle_paths: list[list[bytes]]
    output_values: list[int]
    output_pubkeys: list[bytes]


@dataclass(frozen=True)
class GeneratedProof:
    """Proof returned from the Lumora coprocessor."""
    raw_proof: bytes
    snark_wrapper: bytes | None
    public_inputs: list[bytes]
    proof_type: str
