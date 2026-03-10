import {
  NoteWallet,
  type ShieldedNote,
  type StealthMetaAddress,
} from "../wallet";
import type { Hex } from "viem";

// ── Helpers ───────────────────────────────────────────

const SPENDING_KEY: Hex =
  "0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
const CHAIN_KEY = "avalanche-fuji";

function makeWallet(key = SPENDING_KEY, chain = CHAIN_KEY): NoteWallet {
  return new NoteWallet(key, chain);
}

function addSampleNote(
  wallet: NoteWallet,
  value: bigint,
  leafIndex = 0,
): ShieldedNote {
  return wallet.addNote({
    commitment: `0x${leafIndex.toString(16).padStart(64, "0")}` as Hex,
    leafIndex,
    value,
    secret:
      "0x1111111111111111111111111111111111111111111111111111111111111111",
    nonce: "0x2222222222222222222222222222222222222222222222222222222222222222",
  });
}

// ── Tests ─────────────────────────────────────────────

describe("NoteWallet", () => {
  describe("addNote", () => {
    it("creates a note with correct fields", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 1000n, 0);

      expect(note.value).toBe(1000n);
      expect(note.leafIndex).toBe(0);
      expect(note.chainKey).toBe(CHAIN_KEY);
      expect(note.spent).toBe(false);
      expect(note.nullifier).toBeUndefined();
      expect(typeof note.id).toBe("string");
      expect(note.id.startsWith("0x")).toBe(true);
    });

    it("assigns unique IDs to different notes", () => {
      const w = makeWallet();
      const n1 = addSampleNote(w, 100n, 0);
      const n2 = addSampleNote(w, 200n, 1);
      expect(n1.id).not.toBe(n2.id);
    });

    it("stores the txHash when provided", () => {
      const w = makeWallet();
      const txHash: Hex =
        "0xdeadbeef00000000000000000000000000000000000000000000000000000000";
      const note = w.addNote({
        commitment:
          "0x0000000000000000000000000000000000000000000000000000000000000001",
        leafIndex: 0,
        value: 500n,
        secret:
          "0x1111111111111111111111111111111111111111111111111111111111111111",
        nonce:
          "0x2222222222222222222222222222222222222222222222222222222222222222",
        txHash,
      });
      expect(note.txHash).toBe(txHash);
    });
  });

  describe("getUnspentNotes / getAllNotes", () => {
    it("returns only unspent notes", () => {
      const w = makeWallet();
      const n1 = addSampleNote(w, 100n, 0);
      addSampleNote(w, 200n, 1);

      w.markSpent(
        n1.id,
        "0xaaaa000000000000000000000000000000000000000000000000000000000000",
      );

      expect(w.getUnspentNotes()).toHaveLength(1);
      expect(w.getAllNotes()).toHaveLength(2);
    });
  });

  describe("getBalance", () => {
    it("returns zero for empty wallet", () => {
      expect(makeWallet().getBalance()).toBe(0n);
    });

    it("sums only unspent note values", () => {
      const w = makeWallet();
      const n1 = addSampleNote(w, 100n, 0);
      addSampleNote(w, 300n, 1);
      addSampleNote(w, 50n, 2);

      w.markSpent(
        n1.id,
        "0xaaaa000000000000000000000000000000000000000000000000000000000000",
      );

      expect(w.getBalance()).toBe(350n);
    });
  });

  describe("markSpent", () => {
    it("sets spent flag and nullifier", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 100n, 0);
      const nullifier: Hex =
        "0xbbbb000000000000000000000000000000000000000000000000000000000000";

      w.markSpent(note.id, nullifier);

      const updated = w.getNote(note.id);
      expect(updated?.spent).toBe(true);
      expect(updated?.nullifier).toBe(nullifier);
    });

    it("throws for unknown note ID", () => {
      const w = makeWallet();
      expect(() =>
        w.markSpent(
          "0xnonexistent",
          "0x0000000000000000000000000000000000000000000000000000000000000000",
        ),
      ).toThrow("not found");
    });
  });

  describe("selectNotesForSpend", () => {
    it("selects the fewest notes to cover the target (greedy, largest first)", () => {
      const w = makeWallet();
      addSampleNote(w, 50n, 0);
      addSampleNote(w, 200n, 1);
      addSampleNote(w, 100n, 2);

      const { selected, change } = w.selectNotesForSpend(150n);

      // Greedy picks 200 first → done
      expect(selected).toHaveLength(1);
      expect(selected[0].value).toBe(200n);
      expect(change).toBe(50n);
    });

    it("selects multiple notes when needed", () => {
      const w = makeWallet();
      addSampleNote(w, 50n, 0);
      addSampleNote(w, 60n, 1);
      addSampleNote(w, 70n, 2);

      const { selected, change } = w.selectNotesForSpend(120n);

      // Greedy: 70 + 60 = 130 ≥ 120
      expect(selected).toHaveLength(2);
      expect(change).toBe(10n);
    });

    it("throws when balance is insufficient", () => {
      const w = makeWallet();
      addSampleNote(w, 10n, 0);

      expect(() => w.selectNotesForSpend(100n)).toThrow("Insufficient balance");
    });

    it("ignores spent notes", () => {
      const w = makeWallet();
      const n1 = addSampleNote(w, 1000n, 0);
      addSampleNote(w, 5n, 1);

      w.markSpent(
        n1.id,
        "0xaaaa000000000000000000000000000000000000000000000000000000000000",
      );

      expect(() => w.selectNotesForSpend(10n)).toThrow("Insufficient balance");
    });
  });

  describe("computeNullifier", () => {
    it("returns a 32-byte hex hash", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 100n, 0);

      const nullifier = w.computeNullifier(note, 43113n, 1n);

      expect(nullifier).toMatch(/^0x[0-9a-f]{64}$/);
    });

    it("produces different nullifiers for different chainIds", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 100n, 0);

      const n1 = w.computeNullifier(note, 43113n, 1n);
      const n2 = w.computeNullifier(note, 1287n, 1n);

      expect(n1).not.toBe(n2);
    });

    it("produces different nullifiers for different appIds", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 100n, 0);

      const n1 = w.computeNullifier(note, 43113n, 1n);
      const n2 = w.computeNullifier(note, 43113n, 2n);

      expect(n1).not.toBe(n2);
    });

    it("produces different nullifiers for different spending keys", () => {
      const w1 = makeWallet(SPENDING_KEY);
      const w2 = makeWallet(
        "0x9999999999999999999999999999999999999999999999999999999999999999",
      );

      const note1 = addSampleNote(w1, 100n, 0);
      const note2 = addSampleNote(w2, 100n, 0);

      const n1 = w1.computeNullifier(note1, 43113n, 1n);
      const n2 = w2.computeNullifier(note2, 43113n, 1n);

      expect(n1).not.toBe(n2);
    });
  });

  describe("exportNotes / importNotes", () => {
    it("round-trips all notes correctly", () => {
      const w1 = makeWallet();
      addSampleNote(w1, 100n, 0);
      addSampleNote(w1, 200n, 1);

      const exported = w1.exportNotes();
      expect(exported).toHaveLength(2);

      const w2 = makeWallet();
      w2.importNotes(exported);

      expect(w2.getAllNotes()).toHaveLength(2);
      expect(w2.getBalance()).toBe(300n);
    });

    it("preserves spent status across export/import", () => {
      const w1 = makeWallet();
      const note = addSampleNote(w1, 100n, 0);
      const nul: Hex =
        "0xcccc000000000000000000000000000000000000000000000000000000000000";
      w1.markSpent(note.id, nul);

      const exported = w1.exportNotes();
      const w2 = makeWallet();
      w2.importNotes(exported);

      const imported = w2.getNote(note.id);
      expect(imported?.spent).toBe(true);
      expect(imported?.nullifier).toBe(nul);
      expect(w2.getBalance()).toBe(0n);
    });

    it("serializes bigint values to hex strings", () => {
      const w = makeWallet();
      addSampleNote(w, 1000000000000000000n, 0); // 1 ETH in wei

      const exported = w.exportNotes();
      const entry = exported[0] as Record<string, unknown>;
      expect(typeof entry.value).toBe("string");
      expect((entry.value as string).startsWith("0x")).toBe(true);
    });
  });

  describe("getStealthMetaAddress", () => {
    it("returns well-formed meta-address", () => {
      const w = makeWallet();
      const meta: StealthMetaAddress = w.getStealthMetaAddress();

      expect(meta.spendPubKeyX).toMatch(/^0x[0-9a-f]{64}$/);
      expect(meta.viewPubKeyX).toMatch(/^0x[0-9a-f]{64}$/);
      expect([27, 28]).toContain(meta.spendPubKeyParity);
      expect([27, 28]).toContain(meta.viewPubKeyParity);
    });

    it("derives different keys for spend and view", () => {
      const w = makeWallet();
      const meta = w.getStealthMetaAddress();
      expect(meta.spendPubKeyX).not.toBe(meta.viewPubKeyX);
    });

    it("is deterministic for the same spending key", () => {
      const w1 = makeWallet();
      const w2 = makeWallet();
      expect(w1.getStealthMetaAddress()).toEqual(w2.getStealthMetaAddress());
    });
  });

  describe("getNote", () => {
    it("returns undefined for unknown ID", () => {
      expect(makeWallet().getNote("0xnothing")).toBeUndefined();
    });

    it("returns the correct note by ID", () => {
      const w = makeWallet();
      const note = addSampleNote(w, 42n, 7);
      expect(w.getNote(note.id)).toBe(note);
    });
  });
});
