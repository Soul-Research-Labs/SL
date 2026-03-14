"""Soul Privacy SDK — Python client for the multi-chain ZK privacy stack."""

from soul_privacy.client import SoulPrivacyClient
from soul_privacy.substrate_client import SubstratePrivacyClient
from soul_privacy.cosmwasm_client import CosmWasmPrivacyClient
from soul_privacy.near_client import NearPrivacyClient
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
    "SubstratePrivacyClient",
    "CosmWasmPrivacyClient",
    "NearPrivacyClient",
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
