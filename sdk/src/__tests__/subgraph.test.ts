import {
  SubgraphClient,
  type SubgraphConfig,
  type DepositEntity,
  type TransferEntity,
  type WithdrawalEntity,
  type EpochEntity,
  type PoolMetricsEntity,
} from "../subgraph";

// ── Mock fetch ─────────────────────────────────────────

const mockFetch = jest.fn<Promise<Response>, [string, RequestInit?]>();

function gqlResponse<T>(data: T, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve({ data }),
  } as unknown as Response;
}

function gqlError(message: string): Response {
  return {
    ok: true,
    status: 200,
    json: () => Promise.resolve({ errors: [{ message }] }),
  } as unknown as Response;
}

function failResponse(status: number): Response {
  return {
    ok: false,
    status,
    json: () => Promise.resolve({}),
  } as unknown as Response;
}

const ENDPOINT = "https://api.thegraph.com/subgraphs/name/soul-privacy/pool";

function makeClient(): SubgraphClient {
  return new SubgraphClient({
    endpoint: ENDPOINT,
    fetchFn: mockFetch as unknown as typeof fetch,
  });
}

beforeEach(() => {
  jest.clearAllMocks();
});

// ── Fixtures ───────────────────────────────────────────

const DEPOSIT: DepositEntity = {
  id: "0x01",
  commitment: "0xaabb",
  leafIndex: "42",
  amount: "1000000000000000000",
  timestamp: "1700000000",
  blockNumber: "100",
  transactionHash: "0xtx1",
};

const TRANSFER: TransferEntity = {
  id: "0x02",
  nullifier0: "0xnul0",
  nullifier1: "0xnul1",
  outputCommitment0: "0xout0",
  outputCommitment1: "0xout1",
  newRoot: "0xroot",
  blockNumber: "101",
  transactionHash: "0xtx2",
  timestamp: "1700000100",
};

const WITHDRAWAL: WithdrawalEntity = {
  id: "0x03",
  nullifier0: "0xwnul0",
  nullifier1: "0xwnul1",
  recipient: "0x0000000000000000000000000000000000000001",
  exitValue: "500000000000000000",
  newRoot: "0xwroot",
  blockNumber: "102",
  transactionHash: "0xtx3",
  timestamp: "1700000200",
};

const EPOCH: EpochEntity = {
  id: "epoch-5",
  epochId: "5",
  nullifierRoot: "0xepochroot",
  nullifierCount: "42",
  finalizedAt: "1700001000",
  blockNumber: "200",
  transactionHash: "0xtx4",
};

const METRICS: PoolMetricsEntity = {
  id: "metrics",
  totalDeposits: "100",
  totalWithdrawals: "30",
  totalTransfers: "70",
  totalDepositedValue: "100000000000000000000",
  totalWithdrawnValue: "30000000000000000000",
  uniqueDepositors: "25",
  paused: false,
};

// ── Tests ──────────────────────────────────────────────

describe("SubgraphClient", () => {
  describe("query()", () => {
    it("sends POST with JSON body to endpoint", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ deposits: [DEPOSIT] }),
      );

      const client = makeClient();
      await client.getDeposits();

      expect(mockFetch).toHaveBeenCalledWith(
        ENDPOINT,
        expect.objectContaining({
          method: "POST",
          headers: { "Content-Type": "application/json" },
        }),
      );
    });

    it("throws on HTTP error", async () => {
      mockFetch.mockResolvedValueOnce(failResponse(500));
      const client = makeClient();
      await expect(client.getDeposits()).rejects.toThrow(
        "Subgraph request failed: 500",
      );
    });

    it("throws on GraphQL error", async () => {
      mockFetch.mockResolvedValueOnce(gqlError("Query too complex"));
      const client = makeClient();
      await expect(client.getDeposits()).rejects.toThrow(
        "Subgraph error: Query too complex",
      );
    });
  });

  describe("getDeposits()", () => {
    it("returns deposits array", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ deposits: [DEPOSIT] }),
      );
      const client = makeClient();
      const result = await client.getDeposits();
      expect(result).toHaveLength(1);
      expect(result[0].commitment).toBe("0xaabb");
    });

    it("respects pagination options", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ deposits: [] }),
      );
      const client = makeClient();
      await client.getDeposits({ first: 10, skip: 5 });

      const body = JSON.parse(
        (mockFetch.mock.calls[0][1] as RequestInit).body as string,
      );
      expect(body.query).toContain("first: 10");
      expect(body.query).toContain("skip: 5");
    });
  });

  describe("getDepositByCommitment()", () => {
    it("returns matching deposit", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ deposits: [DEPOSIT] }),
      );
      const client = makeClient();
      const result = await client.getDepositByCommitment("0xaabb");
      expect(result).not.toBeNull();
      expect(result!.commitment).toBe("0xaabb");
    });

    it("returns null when not found", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ deposits: [] }),
      );
      const client = makeClient();
      expect(await client.getDepositByCommitment("0xffff")).toBeNull();
    });

    it("rejects invalid hex input", async () => {
      const client = makeClient();
      await expect(
        client.getDepositByCommitment('"; DROP TABLE deposits; --'),
      ).rejects.toThrow("Invalid hex value");
    });
  });

  describe("getTransfers()", () => {
    it("returns transfers array", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ transfers: [TRANSFER] }),
      );
      const client = makeClient();
      const result = await client.getTransfers();
      expect(result).toHaveLength(1);
      expect(result[0].nullifier0).toBe("0xnul0");
    });
  });

  describe("getTransferByNullifier()", () => {
    it("finds by nullifier0", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ transfers: [TRANSFER] }),
      );
      const client = makeClient();
      const result = await client.getTransferByNullifier("0xnul0");
      expect(result).not.toBeNull();
    });

    it("falls back to nullifier1", async () => {
      mockFetch
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        .mockResolvedValueOnce(gqlResponse({ transfers: [TRANSFER] }));
      const client = makeClient();
      const result = await client.getTransferByNullifier("0xnul1");
      expect(result).not.toBeNull();
      expect(mockFetch).toHaveBeenCalledTimes(2);
    });

    it("returns null when not found anywhere", async () => {
      mockFetch
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }));
      const client = makeClient();
      expect(await client.getTransferByNullifier("0xabcd")).toBeNull();
    });
  });

  describe("getWithdrawals()", () => {
    it("returns withdrawals array", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ withdrawals: [WITHDRAWAL] }),
      );
      const client = makeClient();
      const result = await client.getWithdrawals();
      expect(result).toHaveLength(1);
      expect(result[0].recipient).toBe(
        "0x0000000000000000000000000000000000000001",
      );
    });
  });

  describe("getWithdrawalsByRecipient()", () => {
    it("queries with lowercased address", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ withdrawals: [WITHDRAWAL] }),
      );
      const client = makeClient();
      await client.getWithdrawalsByRecipient(
        "0x0000000000000000000000000000000000000001",
      );

      const body = JSON.parse(
        (mockFetch.mock.calls[0][1] as RequestInit).body as string,
      );
      expect(body.query).toContain("recipient:");
    });

    it("rejects invalid address", async () => {
      const client = makeClient();
      await expect(
        client.getWithdrawalsByRecipient("not-an-address"),
      ).rejects.toThrow("Invalid address");
    });
  });

  describe("getEpochs()", () => {
    it("returns epochs array", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ epochs: [EPOCH] }),
      );
      const client = makeClient();
      const result = await client.getEpochs();
      expect(result).toHaveLength(1);
      expect(result[0].epochId).toBe("5");
    });
  });

  describe("getLatestEpoch()", () => {
    it("returns the latest epoch", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ epochs: [EPOCH] }),
      );
      const client = makeClient();
      const epoch = await client.getLatestEpoch();
      expect(epoch).not.toBeNull();
      expect(epoch!.epochId).toBe("5");
    });

    it("returns null for empty set", async () => {
      mockFetch.mockResolvedValueOnce(gqlResponse({ epochs: [] }));
      const client = makeClient();
      expect(await client.getLatestEpoch()).toBeNull();
    });
  });

  describe("getPoolMetrics()", () => {
    it("returns metrics entity", async () => {
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ poolMetrics: METRICS }),
      );
      const client = makeClient();
      const metrics = await client.getPoolMetrics();
      expect(metrics).not.toBeNull();
      expect(metrics!.totalDeposits).toBe("100");
      expect(metrics!.paused).toBe(false);
    });
  });

  describe("isNullifierSpent()", () => {
    it("returns true when found in transfers", async () => {
      // getTransferByNullifier finds it in nullifier0
      mockFetch.mockResolvedValueOnce(
        gqlResponse({ transfers: [TRANSFER] }),
      );
      const client = makeClient();
      expect(await client.isNullifierSpent("0xnul0")).toBe(true);
    });

    it("returns true when found in withdrawals", async () => {
      // Transfer lookup returns nothing
      mockFetch
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        // Withdrawal nullifier0 check
        .mockResolvedValueOnce(
          gqlResponse({ withdrawals: [{ id: "w1" }] }),
        );
      const client = makeClient();
      expect(await client.isNullifierSpent("0xaabb")).toBe(true);
    });

    it("returns false when not found anywhere", async () => {
      mockFetch
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        .mockResolvedValueOnce(gqlResponse({ transfers: [] }))
        .mockResolvedValueOnce(gqlResponse({ withdrawals: [] }))
        .mockResolvedValueOnce(gqlResponse({ withdrawals: [] }));
      const client = makeClient();
      expect(await client.isNullifierSpent("0xccdd")).toBe(false);
    });
  });

  describe("input sanitization", () => {
    it("rejects GraphQL injection in commitment lookup", async () => {
      const client = makeClient();
      await expect(
        client.getDepositByCommitment("0x00\" } ) { id } __schema { types { name"),
      ).rejects.toThrow("Invalid hex value");
    });

    it("rejects non-hex in nullifier lookup", async () => {
      const client = makeClient();
      await expect(
        client.getTransferByNullifier("malicious-input"),
      ).rejects.toThrow("Invalid hex value");
    });

    it("rejects malformed address in recipient lookup", async () => {
      const client = makeClient();
      await expect(
        client.getWithdrawalsByRecipient("0xZZZZ"),
      ).rejects.toThrow("Invalid address");
    });
  });
});
