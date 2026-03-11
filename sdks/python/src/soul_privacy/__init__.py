"""Soul Privacy SDK — Python client for the multi-chain ZK privacy stack."""

from soul_privacy.client import SoulPrivacyClient
from soul_privacy.prover import ProofClient
from soul_privacy.wallet import NoteWallet
from soul_privacy.types import (
    ChainConfig,
    ChainType,
    GeneratedProof,
    Note,
    NullifierInfo,
    ProofRequest,
)

__all__ = [
    "SoulPrivacyClient",
    "ProofClient",
    "NoteWallet",
    "ChainConfig",
    "ChainType",
    "GeneratedProof",
    "Note",
    "NullifierInfo",
    "ProofRequest",
]

__version__ = "0.1.0"
