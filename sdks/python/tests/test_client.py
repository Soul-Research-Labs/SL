"""Tests for SoulPrivacyClient — on-chain pool interaction."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from soul_privacy.client import SoulPrivacyClient, PRIVACY_POOL_ABI
from soul_privacy.types import ChainConfig, ChainType


@pytest.fixture()
def config() -> ChainConfig:
    return ChainConfig(
        chain_id=43113,
        rpc_url="http://localhost:8545",
        pool_address="0x" + "ab" * 20,
        epoch_manager_address="0x" + "cd" * 20,
        chain_type=ChainType.EVM,
    )


@pytest.fixture()
def mock_contract():
    """Return a mock Web3 contract with callable function stubs."""
    contract = MagicMock()
    contract.functions.getLatestRoot.return_value.call.return_value = b"\x01" * 32
    contract.functions.isKnownRoot.return_value.call.return_value = True
    contract.functions.isSpent.return_value.call.return_value = False
    contract.functions.poolBalance.return_value.call.return_value = 10**18
    contract.functions.commitmentExists.return_value.call.return_value = True
    # For tx builders, build_transaction returns a dict
    contract.functions.deposit.return_value.build_transaction.return_value = {"to": "0x00"}
    contract.functions.transfer.return_value.build_transaction.return_value = {"to": "0x00"}
    contract.functions.withdraw.return_value.build_transaction.return_value = {"to": "0x00"}
    return contract


class TestSoulPrivacyClient:
    """Unit tests for the EVM privacy pool client."""

    def _make_client(self, config: ChainConfig, mock_contract: MagicMock) -> SoulPrivacyClient:
        with patch("soul_privacy.client.Web3") as MockWeb3:
            instance = MockWeb3.return_value
            instance.eth.contract.return_value = mock_contract
            MockWeb3.HTTPProvider.return_value = MagicMock()
            MockWeb3.to_checksum_address.side_effect = lambda x: x
            client = SoulPrivacyClient(config)
            client._pool = mock_contract
        return client

    def test_chain_id(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.chain_id == 43113

    def test_pool_address(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.pool_address == config.pool_address

    def test_get_latest_root(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        root = client.get_latest_root()
        assert root == b"\x01" * 32
        mock_contract.functions.getLatestRoot.assert_called_once()

    def test_is_known_root(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.is_known_root(b"\x01" * 32) is True

    def test_is_nullifier_spent(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.is_nullifier_spent(b"\x02" * 32) is False

    def test_get_pool_balance(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.get_pool_balance() == 10**18

    def test_commitment_exists(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        assert client.commitment_exists(b"\x03" * 32) is True

    def test_build_deposit_tx(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        tx = client.build_deposit_tx(
            commitment=b"\x01" * 32,
            amount=10**17,
            sender="0x" + "11" * 20,
        )
        assert isinstance(tx, dict)
        mock_contract.functions.deposit.assert_called_once_with(b"\x01" * 32, 10**17)

    def test_build_transfer_tx(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        tx = client.build_transfer_tx(
            proof=b"\xaa" * 64,
            merkle_root=b"\x01" * 32,
            nullifiers=(b"\x02" * 32, b"\x03" * 32),
            output_commitments=(b"\x04" * 32, b"\x05" * 32),
            domain_chain_id=43113,
            domain_app_id=1,
            sender="0x" + "11" * 20,
        )
        assert isinstance(tx, dict)

    def test_build_withdraw_tx(self, config: ChainConfig, mock_contract: MagicMock) -> None:
        client = self._make_client(config, mock_contract)
        tx = client.build_withdraw_tx(
            proof=b"\xbb" * 64,
            merkle_root=b"\x01" * 32,
            nullifiers=(b"\x02" * 32, b"\x03" * 32),
            output_commitments=(b"\x04" * 32, b"\x05" * 32),
            recipient="0x" + "cc" * 20,
            exit_value=10**17,
            sender="0x" + "11" * 20,
        )
        assert isinstance(tx, dict)


class TestPrivacyPoolABI:
    """Sanity checks on the embedded ABI."""

    def test_abi_has_deposit(self) -> None:
        names = [e["name"] for e in PRIVACY_POOL_ABI]
        assert "deposit" in names

    def test_abi_has_transfer(self) -> None:
        names = [e["name"] for e in PRIVACY_POOL_ABI]
        assert "transfer" in names

    def test_abi_has_withdraw(self) -> None:
        names = [e["name"] for e in PRIVACY_POOL_ABI]
        assert "withdraw" in names

    def test_abi_has_view_functions(self) -> None:
        names = [e["name"] for e in PRIVACY_POOL_ABI]
        assert "getLatestRoot" in names
        assert "isKnownRoot" in names
        assert "isSpent" in names
        assert "poolBalance" in names
        assert "commitmentExists" in names
