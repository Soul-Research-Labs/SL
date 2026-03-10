import { type Hex, type Address, keccak256, encodePacked, toHex } from "viem";

// ── Types ──────────────────────────────────────────────

/** A shielded note in the privacy pool. */
export interface ShieldedNote {
  /** Unique identifier: hash of (commitment, leafIndex, chainKey). */
  id: string;
  /** The on-chain commitment (Poseidon hash). */
  commitment: Hex;
  /** Leaf index in the Merkle tree. */
  leafIndex: number;
  /** Note value in native token (wei). */
  value: bigint;
  /** Secret (spending key component). */
  secret: Hex;
  /** Random nonce / blinding factor. */
  nonce: Hex;
  /** Chain where the note lives. */
  chainKey: string;
  /** Whether this note has been spent (nullified). */
  spent: boolean;
  /** The nullifier for this note (computed lazily). */
  nullifier?: Hex;
  /** Timestamp when the note was created. */
  createdAt: number;
  /** Transaction hash of the deposit/transfer that created this note. */
  txHash?: Hex;
}

/** Parameters needed to spend a note. */
export interface SpendParams {
  note: ShieldedNote;
  /** Merkle path siblings (32 hashes for depth-32 tree). */
  merklePath: Hex[];
  /** Merkle path direction bits (0 = left, 1 = right). */
  pathIndices: number[];
}

/** Stealth meta-address for receiving private payments. */
export interface StealthMetaAddress {
  /** Spend public key x-coordinate. */
  spendPubKeyX: Hex;
  spendPubKeyParity: number;
  /** View public key x-coordinate. */
  viewPubKeyX: Hex;
  viewPubKeyParity: number;
}

/** Encrypted note backup format for storage. */
export interface EncryptedNoteBackup {
  /** Encrypted payload (AES-256-GCM with key derived from spending key). */
  ciphertext: string;
  /** Initialization vector. */
  iv: string;
  /** Version of the encryption scheme. */
  version: number;
}

// ── Note Wallet ────────────────────────────────────────

/**
 * Client-side wallet for managing shielded notes.
 *
 * Tracks unspent notes, computes nullifiers, selects notes for spending,
 * and manages stealth addresses. Notes are stored in-memory — callers
 * should persist via `exportNotes()` / `importNotes()`.
 */
export class NoteWallet {
  private notes: Map<string, ShieldedNote> = new Map();
  private spendingKey: Hex;
  private chainKey: string;

  constructor(spendingKey: Hex, chainKey: string) {
    this.spendingKey = spendingKey;
    this.chainKey = chainKey;
  }

  // ── Note Creation ──────────────────────────────────

  /**
   * Create a new shielded note (e.g., after a deposit).
   * The commitment should match what was submitted on-chain.
   */
  addNote(params: {
    commitment: Hex;
    leafIndex: number;
    value: bigint;
    secret: Hex;
    nonce: Hex;
    txHash?: Hex;
  }): ShieldedNote {
    const id = this.computeNoteId(
      params.commitment,
      params.leafIndex,
      this.chainKey,
    );

    const note: ShieldedNote = {
      id,
      commitment: params.commitment,
      leafIndex: params.leafIndex,
      value: params.value,
      secret: params.secret,
      nonce: params.nonce,
      chainKey: this.chainKey,
      spent: false,
      createdAt: Date.now(),
      txHash: params.txHash,
    };

    this.notes.set(id, note);
    return note;
  }

  /**
   * Mark a note as spent (after a transfer or withdrawal).
   */
  markSpent(noteId: string, nullifier: Hex): void {
    const note = this.notes.get(noteId);
    if (!note) throw new Error(`Note ${noteId} not found`);
    note.spent = true;
    note.nullifier = nullifier;
  }

  // ── Queries ────────────────────────────────────────

  /** Get all unspent notes. */
  getUnspentNotes(): ShieldedNote[] {
    return Array.from(this.notes.values()).filter((n) => !n.spent);
  }

  /** Get all notes (including spent). */
  getAllNotes(): ShieldedNote[] {
    return Array.from(this.notes.values());
  }

  /** Get total shielded balance (sum of unspent note values). */
  getBalance(): bigint {
    return this.getUnspentNotes().reduce((sum, n) => sum + n.value, 0n);
  }

  /** Get a note by ID. */
  getNote(noteId: string): ShieldedNote | undefined {
    return this.notes.get(noteId);
  }

  // ── Note Selection ─────────────────────────────────

  /**
   * Select notes to spend for a target value.
   * Uses a greedy algorithm: picks the fewest notes that cover the target.
   * Returns the selected notes and the change value.
   */
  selectNotesForSpend(targetValue: bigint): {
    selected: ShieldedNote[];
    change: bigint;
  } {
    const unspent = this.getUnspentNotes().sort((a, b) =>
      a.value > b.value ? -1 : a.value < b.value ? 1 : 0,
    );

    const selected: ShieldedNote[] = [];
    let total = 0n;

    for (const note of unspent) {
      if (total >= targetValue) break;
      selected.push(note);
      total += note.value;
    }

    if (total < targetValue) {
      throw new Error(
        `Insufficient balance: have ${total}, need ${targetValue}`,
      );
    }

    return { selected, change: total - targetValue };
  }

  // ── Nullifier Computation ──────────────────────────

  /**
   * Compute a domain-separated V2 nullifier for a note.
   * nullifier = hash(hash(spendingKey, commitment), hash(chainId, appId))
   *
   * This is a simplified client-side version using keccak256.
   * The ZK circuit uses Poseidon — the results must match.
   */
  computeNullifier(note: ShieldedNote, chainId: bigint, appId: bigint): Hex {
    const inner = keccak256(
      encodePacked(["bytes32", "bytes32"], [this.spendingKey, note.commitment]),
    );
    const domain = keccak256(
      encodePacked(["uint256", "uint256"], [chainId, appId]),
    );
    return keccak256(encodePacked(["bytes32", "bytes32"], [inner, domain]));
  }

  // ── Import / Export ────────────────────────────────

  /**
   * Export all notes as a JSON-serializable array.
   * Values are serialized as hex strings for BigInt compatibility.
   */
  exportNotes(): object[] {
    return this.getAllNotes().map((n) => ({
      ...n,
      value: toHex(n.value),
    }));
  }

  /**
   * Import notes from a previously exported array.
   */
  importNotes(data: object[]): void {
    for (const raw of data) {
      const entry = raw as Record<string, unknown>;
      const note: ShieldedNote = {
        id: entry.id as string,
        commitment: entry.commitment as Hex,
        leafIndex: entry.leafIndex as number,
        value: BigInt(entry.value as string),
        secret: entry.secret as Hex,
        nonce: entry.nonce as Hex,
        chainKey: entry.chainKey as string,
        spent: entry.spent as boolean,
        nullifier: entry.nullifier as Hex | undefined,
        createdAt: entry.createdAt as number,
        txHash: entry.txHash as Hex | undefined,
      };
      this.notes.set(note.id, note);
    }
  }

  // ── Stealth Address Helpers ────────────────────────

  /**
   * Derive a stealth meta-address from the spending key.
   * In production, this uses proper EC point derivation.
   * Simplified version for SDK interface demonstration.
   */
  getStealthMetaAddress(): StealthMetaAddress {
    const spendHash = keccak256(
      encodePacked(["bytes32", "string"], [this.spendingKey, "spend"]),
    );
    const viewHash = keccak256(
      encodePacked(["bytes32", "string"], [this.spendingKey, "view"]),
    );

    return {
      spendPubKeyX: spendHash,
      spendPubKeyParity: 27,
      viewPubKeyX: viewHash,
      viewPubKeyParity: 27,
    };
  }

  // ── Internal ───────────────────────────────────────

  private computeNoteId(
    commitment: Hex,
    leafIndex: number,
    chainKey: string,
  ): string {
    return keccak256(
      encodePacked(
        ["bytes32", "uint256", "string"],
        [commitment, BigInt(leafIndex), chainKey],
      ),
    );
  }
}
