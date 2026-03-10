import { ProofClient, type ProofResult, type CoprocessorHealth } from "../prover";

// ── Mock fetch ─────────────────────────────────────────

const mockFetch = jest.fn<Promise<Response>, [string, RequestInit?]>();
global.fetch = mockFetch as unknown as typeof fetch;

const HEALTH_RESPONSE: CoprocessorHealth = {
  status: "ok",
  prover: "halo2-ipa",
  snarkWrapper: "groth16-bn254",
  circuitVersion: "0.8.0",
  availableWorkers: 4,
  queueDepth: 0,
};

const PROOF_RESPONSE: Omit<ProofResult, "provingTimeMs"> = {
  success: true,
  proof: "0x" + "ab".repeat(192) as `0x${string}`,
  publicInputs: ["0x01", "0x02"] as `0x${string}`[],
  provingSystem: "halo2-ipa+groth16",
};

function mockJsonResponse(data: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: () => Promise.resolve(JSON.stringify(data)),
    json: () => Promise.resolve(data),
  } as Response;
}

beforeEach(() => {
  jest.clearAllMocks();
});

// ── Tests ──────────────────────────────────────────────

describe("ProofClient", () => {
  const client = new ProofClient({
    coprocessorUrl: "http://localhost:8080",
    timeoutMs: 5000,
  });

  describe("constructor", () => {
    it("strips trailing slashes from URL", () => {
      const c = new ProofClient({ coprocessorUrl: "http://example.com///" });
      // The URL is private, but we can test behavior via health():
      mockFetch.mockResolvedValueOnce(mockJsonResponse(HEALTH_RESPONSE));
      c.health();
      expect(mockFetch).toHaveBeenCalledWith(
        "http://example.com/health",
        expect.anything(),
      );
    });
  });

  describe("health()", () => {
    it("calls GET /health and returns parsed response", async () => {
      mockFetch.mockResolvedValueOnce(mockJsonResponse(HEALTH_RESPONSE));
      const result = await client.health();
      expect(result.status).toBe("ok");
      expect(result.prover).toBe("halo2-ipa");
      expect(result.availableWorkers).toBe(4);
      expect(mockFetch).toHaveBeenCalledWith(
        "http://localhost:8080/health",
        expect.objectContaining({ method: "GET" }),
      );
    });

    it("throws on non-OK response", async () => {
      mockFetch.mockResolvedValueOnce(
        mockJsonResponse({ error: "internal" }, 500),
      );
      await expect(client.health()).rejects.toThrow("Coprocessor request failed (500)");
    });
  });

  describe("generateProof()", () => {
    it("sends POST to /prove/deposit with JSON body", async () => {
      mockFetch.mockResolvedValueOnce(mockJsonResponse(PROOF_RESPONSE));
      const result = await client.generateProof({
        type: "deposit",
        commitment: "0x01" as `0x${string}`,
        value: 1000000000000000000n,
        secret: "0xaabb" as `0x${string}`,
        nonce: "0xccdd" as `0x${string}`,
      });
      expect(result.success).toBe(true);
      expect(result.provingTimeMs).toBeGreaterThanOrEqual(0);
      expect(mockFetch).toHaveBeenCalledWith(
        "http://localhost:8080/prove/deposit",
        expect.objectContaining({ method: "POST" }),
      );
    });

    it("serializes BigInt values as hex strings", async () => {
      mockFetch.mockResolvedValueOnce(mockJsonResponse(PROOF_RESPONSE));
      await client.generateProof({
        type: "deposit",
        commitment: "0x01" as `0x${string}`,
        value: 255n,
        secret: "0xaa" as `0x${string}`,
        nonce: "0xbb" as `0x${string}`,
      });
      const body = mockFetch.mock.calls[0][1]?.body as string;
      expect(body).toContain('"0xff"'); // 255 as hex
    });
  });

  describe("proveTransfer()", () => {
    it("dispatches to /prove/transfer", async () => {
      mockFetch.mockResolvedValueOnce(mockJsonResponse(PROOF_RESPONSE));
      await client.proveTransfer({
        inputCommitments: ["0x01", "0x02"] as [`0x${string}`, `0x${string}`],
        nullifiers: ["0x03", "0x04"] as [`0x${string}`, `0x${string}`],
        outputCommitments: ["0x05", "0x06"] as [`0x${string}`, `0x${string}`],
        merkleRoot: "0x07" as `0x${string}`,
        merklePaths: [["0x10"], ["0x20"]] as [`0x${string}`[], `0x${string}`[]],
        pathIndices: [[0], [1]],
        spendingKey: "0x08" as `0x${string}`,
        chainId: 43113n,
        appId: 1n,
      });
      expect(mockFetch).toHaveBeenCalledWith(
        "http://localhost:8080/prove/transfer",
        expect.anything(),
      );
    });
  });

  describe("proveWithdraw()", () => {
    it("dispatches to /prove/withdraw", async () => {
      mockFetch.mockResolvedValueOnce(mockJsonResponse(PROOF_RESPONSE));
      await client.proveWithdraw({
        inputCommitments: ["0x01", "0x02"] as [`0x${string}`, `0x${string}`],
        nullifiers: ["0x03", "0x04"] as [`0x${string}`, `0x${string}`],
        outputCommitment: "0x05" as `0x${string}`,
        merkleRoot: "0x06" as `0x${string}`,
        merklePaths: [["0x10"], ["0x20"]] as [`0x${string}`[], `0x${string}`[]],
        pathIndices: [[0], [1]],
        spendingKey: "0x07" as `0x${string}`,
        recipient: "0x0000000000000000000000000000000000000001" as `0x${string}`,
        exitValue: 1000000000000000000n,
        chainId: 43113n,
        appId: 1n,
      });
      expect(mockFetch).toHaveBeenCalledWith(
        "http://localhost:8080/prove/withdraw",
        expect.anything(),
      );
    });
  });
});
