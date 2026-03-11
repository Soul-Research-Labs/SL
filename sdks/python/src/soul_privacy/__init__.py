"""Soul Privacy SDK — Python client for the multi-chain ZK privacy stack."""

from soul_privacy.client import SoulPrivacyClient
from soul_privacy.wallet import NoteWallet
from soul_privacy.types import ChainConfig, Note, NullifierInfo

__all__ = [
    "SoulPrivacyClient",
    "NoteWallet",
    "ChainConfig",
    "Note",
    "NullifierInfo",
]

__version__ = "0.1.0"
