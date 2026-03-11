"""HTTP client for the Lumora coprocessor proof generation service."""

from __future__ import annotations

import httpx

from soul_privacy.types import GeneratedProof


class ProofClient:
    """Client for requesting ZK proofs from the Lumora coprocessor."""

    def __init__(self, base_url: str = "http://localhost:8080", timeout: float = 120.0) -> None:
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout

    async def health(self) -> dict:
        """Check coprocessor health."""
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(f"{self._base_url}/health")
            resp.raise_for_status()
            return resp.json()

    async def prove_transfer(
        self,
        merkle_root: bytes,
        input_commitments: list[bytes],
        spending_keys: list[bytes],
        merkle_paths: list[list[bytes]],
        path_indices: list[list[int]],
        output_values: list[int],
        output_pubkeys: list[bytes],
        output_blindings: list[bytes],
        chain_id: int,
        app_id: int = 1,
    ) -> GeneratedProof:
        """Request a transfer proof from the coprocessor."""
        payload = {
            "type": "transfer",
            "merkle_root": merkle_root.hex(),
            "input_commitments": [c.hex() for c in input_commitments],
            "spending_keys": [k.hex() for k in spending_keys],
            "merkle_paths": [[s.hex() for s in path] for path in merkle_paths],
            "path_indices": path_indices,
            "output_values": output_values,
            "output_pubkeys": [p.hex() for p in output_pubkeys],
            "output_blindings": [b.hex() for b in output_blindings],
            "chain_id": chain_id,
            "app_id": app_id,
        }

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(f"{self._base_url}/prove/transfer", json=payload)
            resp.raise_for_status()
            return self._parse_proof_response(resp.json())

    async def prove_withdraw(
        self,
        merkle_root: bytes,
        input_commitments: list[bytes],
        spending_keys: list[bytes],
        merkle_paths: list[list[bytes]],
        path_indices: list[list[int]],
        exit_value: int,
        change_pubkey: bytes,
        change_blinding: bytes,
        chain_id: int,
        app_id: int = 1,
    ) -> GeneratedProof:
        """Request a withdrawal proof from the coprocessor."""
        payload = {
            "type": "withdraw",
            "merkle_root": merkle_root.hex(),
            "input_commitments": [c.hex() for c in input_commitments],
            "spending_keys": [k.hex() for k in spending_keys],
            "merkle_paths": [[s.hex() for s in path] for path in merkle_paths],
            "path_indices": path_indices,
            "exit_value": exit_value,
            "change_pubkey": change_pubkey.hex(),
            "change_blinding": change_blinding.hex(),
            "chain_id": chain_id,
            "app_id": app_id,
        }

        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.post(f"{self._base_url}/prove/withdraw", json=payload)
            resp.raise_for_status()
            return self._parse_proof_response(resp.json())

    @staticmethod
    def _parse_proof_response(data: dict) -> GeneratedProof:
        return GeneratedProof(
            raw_proof=bytes.fromhex(data["proof"]),
            snark_wrapper=(
                bytes.fromhex(data["snarkWrapper"]) if data.get("snarkWrapper") else None
            ),
            public_inputs=[bytes.fromhex(pi) for pi in data["publicInputs"]],
            proof_type=data.get("provingSystem", "unknown"),
        )
