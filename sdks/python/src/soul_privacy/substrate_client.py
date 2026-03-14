"""Substrate (Polkadot/Polkadex) client for the Soul Privacy SDK.

Communicates with Substrate nodes via JSON-RPC, targeting the privacy-pool
pallet installed on parachains (Moonbeam, Astar, etc.).  Uses the standard
Substrate state/author RPC namespace so it works with any HTTP endpoint.
"""

from __future__ import annotations

from typing import Any

import httpx

from soul_privacy.types import ChainConfig, ChainType


class SubstratePrivacyClient:
    """Client for interacting with the privacy-pool Substrate pallet."""

    def __init__(self, config: ChainConfig) -> None:
        if config.chain_type != ChainType.SUBSTRATE:
            raise ValueError(f"Expected SUBSTRATE chain config, got {config.chain_type}")
        self._config = config
        self._url = config.rpc_url
        self._req_id = 0

    @property
    def chain_id(self) -> int:
        return self._config.chain_id

    # ── Pallet Queries ────────────────────────────────────────────────

    async def get_latest_root(self) -> str:
        """Query the current Merkle root from the privacy-pool pallet."""
        return await self._state_call("PrivacyPool", "latest_root", [])

    async def is_nullifier_spent(self, nullifier_hex: str) -> bool:
        """Check if a nullifier has been spent."""
        result = await self._state_call(
            "PrivacyPool", "is_nullifier_spent", [nullifier_hex]
        )
        return bool(result)

    async def get_pool_balance(self) -> int:
        """Get the total pool balance."""
        result = await self._state_call("PrivacyPool", "pool_balance", [])
        return int(result)

    async def get_epoch_id(self) -> int:
        """Get the current epoch ID."""
        result = await self._state_call("PrivacyPool", "current_epoch", [])
        return int(result)

    # ── Extrinsic Building ────────────────────────────────────────────

    def build_deposit_call(
        self,
        commitment_hex: str,
        amount: int,
    ) -> dict[str, Any]:
        """Build an unsigned deposit extrinsic payload.

        The caller is responsible for signing and submitting via
        ``author_submitExtrinsic``.
        """
        return {
            "pallet": "PrivacyPool",
            "call": "deposit",
            "args": {
                "commitment": commitment_hex,
                "amount": str(amount),
            },
        }

    def build_transfer_call(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        domain_chain_id: int,
        domain_app_id: int = 1,
    ) -> dict[str, Any]:
        """Build an unsigned transfer extrinsic payload."""
        return {
            "pallet": "PrivacyPool",
            "call": "transfer",
            "args": {
                "proof": proof_hex,
                "merkle_root": merkle_root_hex,
                "nullifiers": list(nullifiers),
                "output_commitments": list(output_commitments),
                "domain_chain_id": domain_chain_id,
                "domain_app_id": domain_app_id,
            },
        }

    def build_withdraw_call(
        self,
        proof_hex: str,
        merkle_root_hex: str,
        nullifiers: tuple[str, str],
        output_commitments: tuple[str, str],
        recipient: str,
        exit_value: int,
    ) -> dict[str, Any]:
        """Build an unsigned withdrawal extrinsic payload."""
        return {
            "pallet": "PrivacyPool",
            "call": "withdraw",
            "args": {
                "proof": proof_hex,
                "merkle_root": merkle_root_hex,
                "nullifiers": list(nullifiers),
                "output_commitments": list(output_commitments),
                "recipient": recipient,
                "exit_value": str(exit_value),
            },
        }

    # ── RPC Internals ─────────────────────────────────────────────────

    async def _state_call(
        self, pallet: str, method: str, params: list[Any]
    ) -> Any:
        """Execute a state query via ``state_call`` RPC."""
        self._req_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._req_id,
            "method": "state_call",
            "params": [f"{pallet}_{method}", "0x" + _encode_params(params)],
        }
        async with httpx.AsyncClient() as client:
            resp = await client.post(self._url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        if "error" in data:
            raise RuntimeError(f"RPC error: {data['error']}")
        return data.get("result")

    async def _rpc(self, method: str, params: list[Any] | None = None) -> Any:
        """Low-level JSON-RPC call."""
        self._req_id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._req_id,
            "method": method,
            "params": params or [],
        }
        async with httpx.AsyncClient() as client:
            resp = await client.post(self._url, json=payload)
            resp.raise_for_status()
            data = resp.json()
        if "error" in data:
            raise RuntimeError(f"RPC error: {data['error']}")
        return data.get("result")


def _encode_params(params: list[Any]) -> str:
    """Minimal hex encoding for state_call parameters."""
    parts: list[str] = []
    for p in params:
        if isinstance(p, str) and p.startswith("0x"):
            parts.append(p[2:])
        elif isinstance(p, int):
            parts.append(f"{p:064x}")
        else:
            parts.append(str(p))
    return "".join(parts)
