"""Tests for ProofClient — Lumora coprocessor HTTP client."""

from __future__ import annotations

import pytest
import httpx

from soul_privacy.prover import ProofClient
from soul_privacy.types import GeneratedProof


# ── Fixtures ──

MOCK_PROOF_RESPONSE = {
    "proof": "aa" * 64,
    "publicInputs": ["bb" * 32, "cc" * 32],
    "provingSystem": "ultraplonk",
}


@pytest.fixture()
def prover() -> ProofClient:
    return ProofClient(base_url="http://localhost:9999", timeout=5.0)


# ── Response Parsing ──

class TestParseProofResponse:
    def test_parse_basic_response(self) -> None:
        result = ProofClient._parse_proof_response(MOCK_PROOF_RESPONSE)
        assert isinstance(result, GeneratedProof)
        assert result.raw_proof == bytes.fromhex("aa" * 64)
        assert len(result.public_inputs) == 2
        assert result.proof_type == "ultraplonk"
        assert result.snark_wrapper is None

    def test_parse_with_snark_wrapper(self) -> None:
        resp = {**MOCK_PROOF_RESPONSE, "snarkWrapper": "dd" * 32}
        result = ProofClient._parse_proof_response(resp)
        assert result.snark_wrapper == bytes.fromhex("dd" * 32)

    def test_parse_missing_proving_system_defaults_unknown(self) -> None:
        resp = {
            "proof": "00" * 32,
            "publicInputs": [],
        }
        result = ProofClient._parse_proof_response(resp)
        assert result.proof_type == "unknown"


# ── Health Check ──

class TestHealth:
    @pytest.mark.asyncio
    async def test_health_success(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(url="http://localhost:9999/health", json={"status": "ok"})
        result = await prover.health()
        assert result == {"status": "ok"}

    @pytest.mark.asyncio
    async def test_health_server_error(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(url="http://localhost:9999/health", status_code=500)
        with pytest.raises(httpx.HTTPStatusError):
            await prover.health()


# ── prove_transfer ──

class TestProveTransfer:
    @pytest.mark.asyncio
    async def test_prove_transfer_success(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(
            url="http://localhost:9999/prove/transfer",
            json=MOCK_PROOF_RESPONSE,
        )
        result = await prover.prove_transfer(
            merkle_root=b"\x01" * 32,
            input_commitments=[b"\x02" * 32],
            spending_keys=[b"\x03" * 32],
            merkle_paths=[[b"\x04" * 32]],
            path_indices=[[0]],
            output_values=[500, 500],
            output_pubkeys=[b"\x05" * 32, b"\x06" * 32],
            output_blindings=[b"\x07" * 32, b"\x08" * 32],
            chain_id=43113,
            app_id=1,
        )
        assert isinstance(result, GeneratedProof)
        assert result.proof_type == "ultraplonk"

    @pytest.mark.asyncio
    async def test_prove_transfer_sends_correct_payload(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(
            url="http://localhost:9999/prove/transfer",
            json=MOCK_PROOF_RESPONSE,
        )
        await prover.prove_transfer(
            merkle_root=b"\x01" * 32,
            input_commitments=[b"\x02" * 32],
            spending_keys=[b"\x03" * 32],
            merkle_paths=[[b"\x04" * 32]],
            path_indices=[[0]],
            output_values=[1000],
            output_pubkeys=[b"\x05" * 32],
            output_blindings=[b"\x06" * 32],
            chain_id=43113,
        )
        request = httpx_mock.get_request()
        import json
        body = json.loads(request.content)
        assert body["type"] == "transfer"
        assert body["chain_id"] == 43113
        assert body["app_id"] == 1
        assert body["merkle_root"] == "01" * 32


# ── prove_withdraw ──

class TestProveWithdraw:
    @pytest.mark.asyncio
    async def test_prove_withdraw_success(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(
            url="http://localhost:9999/prove/withdraw",
            json=MOCK_PROOF_RESPONSE,
        )
        result = await prover.prove_withdraw(
            merkle_root=b"\x01" * 32,
            input_commitments=[b"\x02" * 32],
            spending_keys=[b"\x03" * 32],
            merkle_paths=[[b"\x04" * 32]],
            path_indices=[[0]],
            exit_value=1000,
            change_pubkey=b"\x05" * 32,
            change_blinding=b"\x06" * 32,
            chain_id=43113,
        )
        assert isinstance(result, GeneratedProof)

    @pytest.mark.asyncio
    async def test_prove_withdraw_http_error(self, prover: ProofClient, httpx_mock) -> None:
        httpx_mock.add_response(
            url="http://localhost:9999/prove/withdraw",
            status_code=400,
            json={"error": "invalid proof request"},
        )
        with pytest.raises(httpx.HTTPStatusError):
            await prover.prove_withdraw(
                merkle_root=b"\x01" * 32,
                input_commitments=[b"\x02" * 32],
                spending_keys=[b"\x03" * 32],
                merkle_paths=[[b"\x04" * 32]],
                path_indices=[[0]],
                exit_value=1000,
                change_pubkey=b"\x05" * 32,
                change_blinding=b"\x06" * 32,
                chain_id=43113,
            )
