"""NEAR client for the Soul Privacy SDK.

Communicates with a NEAR node via the JSON-RPC interface, targeting the
``privacy-pool`` smart contract deployed on NEAR.
"""

from __future__ import annotations

import base64
import json
from typing import Any

import httpx

from soul_privacy.types import ChainConfig, ChainType


class NearPrivacyClient:
    """Client for interacting with the NEAR privacy-pool contract."""

    def __init__(
        self,
        config: ChainConfig,
        contract_id: str,
        rpc_url: str | None = None,
    ) -> None:
        if config.chain_type != ChainType.NEAR:
            raise ValueError(f"Expected NEAR chain config, got {config.chain_type}")
        self._config = config
        self._url = (rpc_url or "https://rpc.testnet.near.org").rstrip("/")
        self._contract_id = contract_id

    @property
    def chain_id(self) -> int:
        return self._config.chain_id

    @property
    def contract_id(self) -> str:
        return self._contract_id

    # ── View Calls ────────────────────────────────────────────────────

    async def get_latest_root(self) -> str:
        """Query the current Merkle root."""
        result = await self._view("get_root", {})
        return result if isinstance(result, str) else ""

    async def is_nullifier_spent(self, nullifier_hex: str) -> bool:
        """Check if a nullifier has been spent."""
        result = await self._view("is_spent", {"nullifier": nullifier_hex})
        return bool(result)

    async def get_pool_balance(self) -> int:
        """Get the total pool balance in yoctoNEAR."""
        result = await self._view("pool_balance", {})
        return int(result) if result else 0

    async def get_epoch(self) -> int:
        """Get the current epoch ID."""
        result = await self._view("current_epoch", {})
        return int(result) if result else 0

    async def commitment_exists(self, commitment_hex: str) -> bool:
        """Check if a commitment has been deposited."""
        result = await self._view(
            "commitment_exists", {"commitment": commitment_hex}
        )
        return bool(result)

    # ── Function Call Building ────────────────────────────────────────

    def build_deposit_action(
        self,
        commitment_hex: str,
        amount_yocto: int,
    ) -> dict[str, Any]:
        """Build a deposit function-call action for NEAR.

        Returns a dict that can be used with ``near-api-py`` or wrapped
        in a NEAR ``FunctionCall`` action.
        """
        return {
            "contract_id": self._contract_id,
            "method_name": "deposit",
            "args": json.dumps({"commitment": commitment_hex}).encode().decode(),
            "gas": 100_000_000_000_000,  # 100 TGas
            "deposit": str(amount_yocto),
        }

    def build_transfer_action(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        domain_chain_id: int,
        domain_app_id: int = 1,
    ) -> dict[str, Any]:
        """Build a transfer function-call action."""
        return {
            "contract_id": self._contract_id,
            "method_name": "transfer",
            "args": json.dumps({
                "proof": proof_hex,
                "merkle_root": merkle_root_hex,
                "nullifiers": list(nullifiers),
                "output_commitments": list(output_commitments),
                "domain_chain_id": domain_chain_id,
                "domain_app_id": domain_app_id,
            }).encode().decode(),
            "gas": 300_000_000_000_000,  # 300 TGas (proof verification is heavy)
            "deposit": "0",
        }

    def build_withdraw_action(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        recipient: str,
        exit_value: int,
    ) -> dict[str, Any]:
        """Build a withdrawal function-call action."""
        return {
            "contract_id": self._contract_id,
            "method_name": "withdraw",
            "args": json.dumps({
                "proof": proof_hex,
                "merkle_root": merkle_root_hex,
                "nullifiers": list(nullifiers),
                "output_commitments": list(output_commitments),
                "recipient": recipient,
                "exit_value": str(exit_value),
            }).encode().decode(),
            "gas": 300_000_000_000_000,
            "deposit": "0",
        }

    # ── NEAR RPC Internals ────────────────────────────────────────────

    async def _view(self, method: str, args: dict[str, Any]) -> Any:
        """Call a NEAR view function via ``query/call_function``."""
        args_b64 = base64.b64encode(json.dumps(args).encode()).decode()
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "query",
            "params": {
                "request_type": "call_function",
                "finality": "final",
                "account_id": self._contract_id,
                "method_name": method,
                "args_base64": args_b64,
            },
        }
        async with httpx.AsyncClient() as client:
            resp = await client.post(self._url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        if "error" in data:
            raise RuntimeError(f"NEAR RPC error: {data['error']}")
        result_bytes = bytes(data["result"]["result"])
        return json.loads(result_bytes)
