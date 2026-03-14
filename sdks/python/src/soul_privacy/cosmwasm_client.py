"""CosmWasm client for the Soul Privacy SDK.

Communicates with a CosmWasm-enabled chain (e.g. Evmos, Osmosis) via the
standard Cosmos REST/RPC interface, targetting the ``privacy-pool`` contract.
"""

from __future__ import annotations

import base64
import json
from typing import Any

import httpx

from soul_privacy.types import ChainConfig, ChainType


class CosmWasmPrivacyClient:
    """Client for interacting with the CosmWasm privacy-pool contract."""

    def __init__(self, config: ChainConfig, contract_address: str) -> None:
        if config.chain_type != ChainType.COSMWASM:
            raise ValueError(f"Expected COSMWASM chain config, got {config.chain_type}")
        self._config = config
        self._url = config.rpc_url.rstrip("/")
        self._contract = contract_address

    @property
    def chain_id(self) -> int:
        return self._config.chain_id

    @property
    def contract_address(self) -> str:
        return self._contract

    # ── Smart-Query Wrappers ──────────────────────────────────────────

    async def get_latest_root(self) -> str:
        """Query the current Merkle root."""
        result = await self._query({"get_root": {}})
        return result.get("root", "")

    async def is_nullifier_spent(self, nullifier_hex: str) -> bool:
        """Check if a nullifier has been spent."""
        result = await self._query({"is_spent": {"nullifier": nullifier_hex}})
        return result.get("spent", False)

    async def get_pool_balance(self) -> int:
        """Get the total pool balance in the accepted denomination."""
        result = await self._query({"pool_balance": {}})
        return int(result.get("balance", 0))

    async def get_config(self) -> dict[str, Any]:
        """Query the contract configuration."""
        return await self._query({"get_config": {}})

    async def get_epoch(self) -> int:
        """Get the current epoch ID."""
        result = await self._query({"current_epoch": {}})
        return int(result.get("epoch_id", 0))

    # ── Message Building ──────────────────────────────────────────────

    def build_deposit_msg(
        self,
        commitment_hex: str,
        amount: int,
        denom: str = "aevmos",
    ) -> dict[str, Any]:
        """Build an unsigned CosmWasm execute message for deposit.

        Returns a dict suitable for inclusion in a Cosmos ``MsgExecuteContract``
        transaction.  The caller signs and broadcasts.
        """
        return {
            "contract": self._contract,
            "msg": {"deposit": {"commitment": commitment_hex}},
            "funds": [{"denom": denom, "amount": str(amount)}],
        }

    def build_transfer_msg(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        domain_chain_id: int,
        domain_app_id: int = 1,
    ) -> dict[str, Any]:
        """Build an unsigned transfer execute message."""
        return {
            "contract": self._contract,
            "msg": {
                "transfer": {
                    "proof": proof_hex,
                    "merkle_root": merkle_root_hex,
                    "nullifiers": list(nullifiers),
                    "output_commitments": list(output_commitments),
                    "domain_chain_id": domain_chain_id,
                    "domain_app_id": domain_app_id,
                },
            },
            "funds": [],
        }

    def build_withdraw_msg(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        recipient: str,
        exit_value: int,
    ) -> dict[str, Any]:
        """Build an unsigned withdrawal execute message."""
        return {
            "contract": self._contract,
            "msg": {
                "withdraw": {
                    "proof": proof_hex,
                    "merkle_root": merkle_root_hex,
                    "nullifiers": list(nullifiers),
                    "output_commitments": list(output_commitments),
                    "recipient": recipient,
                    "exit_value": str(exit_value),
                },
            },
            "funds": [],
        }

    # ── Cosmos LCD Internals ──────────────────────────────────────────

    async def _query(self, query_msg: dict[str, Any]) -> dict[str, Any]:
        """Execute a CosmWasm smart query via the Cosmos LCD API."""
        encoded = base64.b64encode(json.dumps(query_msg).encode()).decode()
        url = (
            f"{self._url}/cosmwasm/wasm/v1/contract/{self._contract}/smart/{encoded}"
        )
        async with httpx.AsyncClient() as client:
            resp = await client.get(url)
            resp.raise_for_status()
            data = resp.json()
        return data.get("data", {})
