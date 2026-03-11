"""Tests for the Soul Privacy Python SDK."""

import pytest

from soul_privacy.types import ChainConfig, ChainType, Note
from soul_privacy.wallet import NoteWallet


class TestNoteWallet:
    """Tests for the NoteWallet class."""

    def _make_wallet(self) -> NoteWallet:
        sk = b"\x01" * 32
        return NoteWallet(spending_key=sk, chain_id=43113, app_id=1)

    def test_initial_balance_is_zero(self) -> None:
        wallet = self._make_wallet()
        assert wallet.balance == 0
        assert wallet.unspent_notes == []

    def test_create_note(self) -> None:
        wallet = self._make_wallet()
        note = wallet.create_note(value=1_000_000)
        assert note.value == 1_000_000
        assert len(note.commitment) == 32
        assert len(note.blinding) == 32
        assert not note.spent
        assert wallet.balance == 1_000_000

    def test_mark_spent(self) -> None:
        wallet = self._make_wallet()
        note = wallet.create_note(value=500)
        wallet.mark_spent(note.commitment)
        assert wallet.balance == 0
        assert len(wallet.unspent_notes) == 0

    def test_mark_spent_unknown_raises(self) -> None:
        wallet = self._make_wallet()
        with pytest.raises(ValueError, match="not found"):
            wallet.mark_spent(b"\x00" * 32)

    def test_select_notes_sufficient(self) -> None:
        wallet = self._make_wallet()
        wallet.create_note(value=100)
        wallet.create_note(value=200)
        wallet.create_note(value=300)
        selected = wallet.select_notes(target_value=250)
        total = sum(n.value for n in selected)
        assert total >= 250

    def test_select_notes_insufficient_raises(self) -> None:
        wallet = self._make_wallet()
        wallet.create_note(value=100)
        with pytest.raises(ValueError, match="Insufficient balance"):
            wallet.select_notes(target_value=500)

    def test_nullifier_v2_deterministic(self) -> None:
        wallet = self._make_wallet()
        cm = b"\xab" * 32
        n1 = wallet.compute_nullifier_v2(cm)
        n2 = wallet.compute_nullifier_v2(cm)
        assert n1 == n2
        assert len(n1) == 32

    def test_nullifier_v2_domain_separation(self) -> None:
        sk = b"\x01" * 32
        cm = b"\xab" * 32
        w1 = NoteWallet(spending_key=sk, chain_id=43113, app_id=1)
        w2 = NoteWallet(spending_key=sk, chain_id=1287, app_id=1)
        assert w1.compute_nullifier_v2(cm) != w2.compute_nullifier_v2(cm)

    def test_export_import_roundtrip(self) -> None:
        wallet = self._make_wallet()
        wallet.create_note(value=1000)
        wallet.create_note(value=2000)

        exported = wallet.export_wallet()

        wallet2 = self._make_wallet()
        wallet2.import_wallet(exported)
        assert wallet2.balance == 3000
        assert len(wallet2.unspent_notes) == 2


class TestChainConfig:
    """Tests for ChainConfig type."""

    def test_create_evm_config(self) -> None:
        config = ChainConfig(
            chain_id=43113,
            rpc_url="https://api.avax-test.network/ext/bc/C/rpc",
            pool_address="0x" + "00" * 20,
            epoch_manager_address="0x" + "00" * 20,
        )
        assert config.chain_id == 43113
        assert config.chain_type == ChainType.EVM

    def test_frozen_config(self) -> None:
        config = ChainConfig(
            chain_id=1287,
            rpc_url="https://rpc.api.moonbase.moonbeam.network",
            pool_address="0x" + "11" * 20,
            epoch_manager_address="0x" + "22" * 20,
        )
        with pytest.raises(AttributeError):
            config.chain_id = 999  # type: ignore[misc]
