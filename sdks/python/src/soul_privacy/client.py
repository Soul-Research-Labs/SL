"""Soul Privacy client for interacting with on-chain privacy pools."""

from __future__ import annotations

from typing import Any

from web3 import Web3
from web3.contract import Contract

from soul_privacy.types import ChainConfig, Note, NullifierInfo


# Minimal ABI for PrivacyPool contract interactions
PRIVACY_POOL_ABI = [
    {
        "type": "function",
        "name": "deposit",
        "inputs": [
            {"name": "commitment", "type": "bytes32"},
            {"name": "amount", "type": "uint256"},
        ],
        "outputs": [],
        "stateMutability": "payable",
    },
    {
        "type": "function",
        "name": "transfer",
        "inputs": [
            {"name": "proof", "type": "bytes"},
            {"name": "merkleRoot", "type": "bytes32"},
            {"name": "nullifiers", "type": "bytes32[2]"},
            {"name": "outputCommitments", "type": "bytes32[2]"},
            {"name": "_domainChainId", "type": "uint256"},
            {"name": "_domainAppId", "type": "uint256"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
    {
        "type": "function",
        "name": "withdraw",
        "inputs": [
            {"name": "proof", "type": "bytes"},
            {"name": "merkleRoot", "type": "bytes32"},
            {"name": "nullifiers", "type": "bytes32[2]"},
            {"name": "outputCommitments", "type": "bytes32[2]"},
            {"name": "recipient", "type": "address"},
            {"name": "exitValue", "type": "uint256"},
        ],
        "outputs": [],
        "stateMutability": "nonpayable",
    },
    {
        "type": "function",
        "name": "isSpent",
        "inputs": [{"name": "nullifier", "type": "bytes32"}],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
    },
    {
        "type": "function",
        "name": "getLatestRoot",
        "inputs": [],
        "outputs": [{"name": "", "type": "bytes32"}],
        "stateMutability": "view",
    },
    {
        "type": "function",
        "name": "isKnownRoot",
        "inputs": [{"name": "root", "type": "bytes32"}],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
    },
    {
        "type": "function",
        "name": "poolBalance",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
    },
    {
        "type": "function",
        "name": "commitmentExists",
        "inputs": [{"name": "commitment", "type": "bytes32"}],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "view",
    },
]


class SoulPrivacyClient:
    """Client for interacting with a single-chain privacy pool deployment."""

    def __init__(self, config: ChainConfig) -> None:
        self._config = config
        self._w3 = Web3(Web3.HTTPProvider(config.rpc_url))
        self._pool: Contract = self._w3.eth.contract(
            address=Web3.to_checksum_address(config.pool_address),
            abi=PRIVACY_POOL_ABI,
        )

    @property
    def chain_id(self) -> int:
        return self._config.chain_id

    @property
    def pool_address(self) -> str:
        return self._config.pool_address

    def get_latest_root(self) -> bytes:
        """Get the current Merkle root."""
        return bytes(self._pool.functions.getLatestRoot().call())

    def is_known_root(self, root: bytes) -> bool:
        """Check if a root exists in the history ring buffer."""
        return self._pool.functions.isKnownRoot(root).call()

    def is_nullifier_spent(self, nullifier: bytes) -> bool:
        """Check if a nullifier has been spent."""
        return self._pool.functions.isSpent(nullifier).call()

    def get_pool_balance(self) -> int:
        """Get total pool balance in wei."""
        return self._pool.functions.poolBalance().call()

    def commitment_exists(self, commitment: bytes) -> bool:
        """Check if a commitment has been deposited."""
        return self._pool.functions.commitmentExists(commitment).call()

    def build_deposit_tx(
        self,
        commitment: bytes,
        amount: int,
        sender: str,
    ) -> dict[str, Any]:
        """Build a deposit transaction (unsigned)."""
        return self._pool.functions.deposit(commitment, amount).build_transaction(
            {
                "from": Web3.to_checksum_address(sender),
                "value": amount,
                "chainId": self._config.chain_id,
            }
        )

    def build_transfer_tx(
        self,
        proof: bytes,
        merkle_root: bytes,
        nullifiers: tuple[bytes, bytes],
        output_commitments: tuple[bytes, bytes],
        domain_chain_id: int,
        domain_app_id: int,
        sender: str,
    ) -> dict[str, Any]:
        """Build a transfer transaction (unsigned)."""
        return self._pool.functions.transfer(
            proof,
            merkle_root,
            list(nullifiers),
            list(output_commitments),
            domain_chain_id,
            domain_app_id,
        ).build_transaction(
            {
                "from": Web3.to_checksum_address(sender),
                "chainId": self._config.chain_id,
            }
        )

    def build_withdraw_tx(
        self,
        proof: bytes,
        merkle_root: bytes,
        nullifiers: tuple[bytes, bytes],
        output_commitments: tuple[bytes, bytes],
        recipient: str,
        exit_value: int,
        sender: str,
    ) -> dict[str, Any]:
        """Build a withdraw transaction (unsigned)."""
        return self._pool.functions.withdraw(
            proof,
            merkle_root,
            list(nullifiers),
            list(output_commitments),
            Web3.to_checksum_address(recipient),
            exit_value,
        ).build_transaction(
            {
                "from": Web3.to_checksum_address(sender),
                "chainId": self._config.chain_id,
            }
        )
