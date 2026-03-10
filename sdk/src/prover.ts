/**
 * SDK client for communicating with the Lumora proof coprocessor.
 *
 * Sends proof generation requests and receives serialized proofs
 * that can be submitted to on-chain privacy pools.
 */

import type { Hex, Address } from "viem";

// ── Types ─────────────────────────────────────────────

/** Supported proof types by the coprocessor. */
export type ProofType = "deposit" | "transfer" | "withdraw";

/** Request to generate a deposit proof. */
export interface DepositProofRequest {
  type: "deposit";
  /** The commitment to prove (Poseidon hash). */
  commitment: Hex;
  /** The deposited value (in wei). */
  value: bigint;
  /** Secret (spending key component). */
  secret: Hex;
  /** Blinding factor / nonce. */
  nonce: Hex;
}

/** Request to generate a transfer proof. */
export interface TransferProofRequest {
  type: "transfer";
  /** Input note commitments being spent. */
  inputCommitments: [Hex, Hex];
  /** Nullifiers for the input notes. */
  nullifiers: [Hex, Hex];
  /** Output note commitments. */
  outputCommitments: [Hex, Hex];
  /** Merkle root the proof is against. */
  merkleRoot: Hex;
  /** Merkle paths for the two input notes. */
  merklePaths: [Hex[], Hex[]];
  /** Path index bits. */
  pathIndices: [number[], number[]];
  /** Spending key. */
  spendingKey: Hex;
  /** Domain chain ID. */
  chainId: bigint;
  /** Domain app ID. */
  appId: bigint;
}

/** Request to generate a withdrawal proof. */
export interface WithdrawProofRequest {
  type: "withdraw";
  /** Input note commitments being spent. */
  inputCommitments: [Hex, Hex];
  /** Nullifiers for input notes. */
  nullifiers: [Hex, Hex];
  /** Output commitment (change note, or zero). */
  outputCommitment: Hex;
  /** Merkle root. */
  merkleRoot: Hex;
  /** Merkle paths. */
  merklePaths: [Hex[], Hex[]];
  /** Path index bits. */
  pathIndices: [number[], number[]];
  /** Spending key. */
  spendingKey: Hex;
  /** Recipient address for the withdrawal. */
  recipient: Address;
  /** Exit value (amount withdrawn). */
  exitValue: bigint;
  /** Domain chain ID. */
  chainId: bigint;
  /** Domain app ID. */
  appId: bigint;
}

export type ProofRequest =
  | DepositProofRequest
  | TransferProofRequest
  | WithdrawProofRequest;

/** Result from the coprocessor. */
export interface ProofResult {
  /** Whether proof generation succeeded. */
  success: boolean;
  /** The serialized proof bytes. */
  proof: Hex;
  /** Public inputs for on-chain verification. */
  publicInputs: Hex[];
  /** The proving system used. */
  provingSystem: string;
  /** Time taken in milliseconds. */
  provingTimeMs: number;
}

/** Coprocessor server health status. */
export interface CoprocessorHealth {
  status: "ok" | "degraded" | "unavailable";
  prover: string;
  snarkWrapper: string;
  circuitVersion: string;
  availableWorkers: number;
  queueDepth: number;
}

// ── Client ────────────────────────────────────────────

export interface ProofClientConfig {
  /** URL of the Lumora coprocessor HTTP service. */
  coprocessorUrl: string;
  /** Request timeout in ms. */
  timeoutMs?: number;
}

/**
 * Client for the Lumora proof coprocessor.
 *
 * Usage:
 * ```ts
 * const client = new ProofClient({ coprocessorUrl: "http://localhost:8080" });
 * const health = await client.health();
 * const result = await client.generateProof({ type: "deposit", ... });
 * ```
 */
export class ProofClient {
  private readonly url: string;
  private readonly timeoutMs: number;

  constructor(config: ProofClientConfig) {
    // Ensure no trailing slash
    this.url = config.coprocessorUrl.replace(/\/+$/, "");
    this.timeoutMs = config.timeoutMs ?? 120_000;
  }

  /** Check coprocessor health and readiness. */
  async health(): Promise<CoprocessorHealth> {
    const res = await this._fetch("/health", { method: "GET" });
    return res as CoprocessorHealth;
  }

  /** Generate a proof for a deposit, transfer, or withdrawal. */
  async generateProof(request: ProofRequest): Promise<ProofResult> {
    const endpoint = `/prove/${request.type}`;

    // Serialize BigInt values as hex strings for JSON transport
    const body = JSON.stringify(request, (_key, value) =>
      typeof value === "bigint" ? `0x${value.toString(16)}` : value,
    );

    const start = Date.now();
    const res = await this._fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });
    const elapsed = Date.now() - start;

    return {
      ...(res as Omit<ProofResult, "provingTimeMs">),
      provingTimeMs: elapsed,
    };
  }

  /**
   * Generate a deposit proof (convenience method).
   * Verifies the commitment matches hash(value, secret, nonce) before sending.
   */
  async proveDeposit(
    params: Omit<DepositProofRequest, "type">,
  ): Promise<ProofResult> {
    return this.generateProof({ type: "deposit", ...params });
  }

  /** Generate a transfer proof (convenience method). */
  async proveTransfer(
    params: Omit<TransferProofRequest, "type">,
  ): Promise<ProofResult> {
    return this.generateProof({ type: "transfer", ...params });
  }

  /** Generate a withdrawal proof (convenience method). */
  async proveWithdraw(
    params: Omit<WithdrawProofRequest, "type">,
  ): Promise<ProofResult> {
    return this.generateProof({ type: "withdraw", ...params });
  }

  // ── Internal ─────────────────────────────────────────

  private async _fetch(path: string, init: RequestInit): Promise<unknown> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await fetch(`${this.url}${path}`, {
        ...init,
        signal: controller.signal,
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(
          `Coprocessor request failed (${response.status}): ${text}`,
        );
      }

      return await response.json();
    } finally {
      clearTimeout(timeout);
    }
  }
}
