"""Client-side shielded note wallet for the Soul Privacy SDK."""

from __future__ import annotations

import json
import secrets
from typing import Any

from soul_privacy.poseidon import poseidon_hash, poseidon_hash_bytes
from soul_privacy.types import Note


class NoteWallet:
    """Client-side shielded note management.

    Provides note tracking, selection for spending, and nullifier computation.
    All data is held in memory — use export/import for persistence.
    """

    def __init__(self, spending_key: bytes, chain_id: int, app_id: int = 1) -> None:
        self._spending_key = spending_key
        self._chain_id = chain_id
        self._app_id = app_id
        self._notes: list[Note] = []

    @property
    def chain_id(self) -> int:
        return self._chain_id

    @property
    def balance(self) -> int:
        """Sum of unspent note values."""
        return sum(n.value for n in self._notes if not n.spent)

    @property
    def unspent_notes(self) -> list[Note]:
        """Return all unspent notes."""
        return [n for n in self._notes if not n.spent]

    def add_note(self, note: Note) -> None:
        """Track a new note in the wallet."""
        self._notes.append(note)

    def create_note(self, value: int, recipient_pubkey: bytes | None = None) -> Note:
        """Create a new note with random blinding factor."""
        blinding = secrets.token_bytes(32)
        pubkey = recipient_pubkey or self._spending_key
        commitment = self._compute_commitment(pubkey, value, blinding)
        note = Note(
            commitment=commitment,
            value=value,
            blinding=blinding,
            owner_pubkey=pubkey,
        )
        self._notes.append(note)
        return note

    def mark_spent(self, commitment: bytes) -> None:
        """Mark a note as spent by its commitment."""
        for i, note in enumerate(self._notes):
            if note.commitment == commitment:
                self._notes[i] = Note(
                    commitment=note.commitment,
                    value=note.value,
                    blinding=note.blinding,
                    owner_pubkey=note.owner_pubkey,
                    leaf_index=note.leaf_index,
                    spent=True,
                )
                return
        raise ValueError(f"Note with commitment {commitment.hex()} not found")

    def select_notes(self, target_value: int) -> list[Note]:
        """Greedy note selection for the given target value.

        Returns a list of unspent notes whose total value >= target_value.
        Raises ValueError if insufficient balance.
        """
        available = sorted(self.unspent_notes, key=lambda n: n.value, reverse=True)
        selected: list[Note] = []
        total = 0
        for note in available:
            selected.append(note)
            total += note.value
            if total >= target_value:
                return selected
        raise ValueError(
            f"Insufficient balance: need {target_value}, have {self.balance}"
        )

    def compute_nullifier_v2(self, commitment: bytes) -> bytes:
        """Compute a domain-separated V2 nullifier.

        V2: Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))
        """
        inner = poseidon_hash_bytes(self._spending_key, commitment)
        domain = poseidon_hash(
            self._chain_id, self._app_id
        ).to_bytes(32, "big")
        return poseidon_hash_bytes(inner, domain)

    def export_wallet(self) -> str:
        """Export wallet state as JSON string."""
        data: dict[str, Any] = {
            "chain_id": self._chain_id,
            "app_id": self._app_id,
            "notes": [
                {
                    "commitment": n.commitment.hex(),
                    "value": n.value,
                    "blinding": n.blinding.hex(),
                    "owner_pubkey": n.owner_pubkey.hex(),
                    "leaf_index": n.leaf_index,
                    "spent": n.spent,
                }
                for n in self._notes
            ],
        }
        return json.dumps(data)

    def import_wallet(self, data_str: str) -> None:
        """Import wallet state from JSON string (appends to existing notes)."""
        data = json.loads(data_str)
        for nd in data["notes"]:
            note = Note(
                commitment=bytes.fromhex(nd["commitment"]),
                value=nd["value"],
                blinding=bytes.fromhex(nd["blinding"]),
                owner_pubkey=bytes.fromhex(nd["owner_pubkey"]),
                leaf_index=nd.get("leaf_index"),
                spent=nd.get("spent", False),
            )
            self._notes.append(note)

    @staticmethod
    def _compute_commitment(pubkey: bytes, value: int, blinding: bytes) -> bytes:
        """Compute note commitment = Poseidon(Poseidon(pubkey, value), blinding)."""
        pk_int = int.from_bytes(pubkey, "big")
        bl_int = int.from_bytes(blinding, "big")
        h = poseidon_hash(poseidon_hash(pk_int, value), bl_int)
        return h.to_bytes(32, "big")
