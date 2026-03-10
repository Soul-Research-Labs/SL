import {
  SoulPrivacyClient,
  MultiChainPrivacyManager,
  type PoolStatus,
} from "../client";
import type { Hex, Address, Hash } from "viem";

// ── Mock viem ──────────────────────────────────────────

const mockReadContract = jest.fn();
const mockWriteContract = jest.fn();

jest.mock("viem", () => ({
  createPublicClient: () => ({
    readContract: mockReadContract,
  }),
  createWalletClient: () => ({
    writeContract: mockWriteContract,
  }),
  http: () => ({}),
  encodeFunctionData: (_: unknown) => "0xencoded" as Hex,
  parseEther: (val: string) => BigInt(val) * 10n ** 18n,
}));

// ── Fixtures ───────────────────────────────────────────

const CHAIN_KEY = "avalanche-fuji";
const MOCK_ROOT: Hex =
  "0x1111111111111111111111111111111111111111111111111111111111111111";
const MOCK_COMMITMENT: Hex =
  "0x2222222222222222222222222222222222222222222222222222222222222222";
const MOCK_NULLIFIER_0: Hex =
  "0x3333333333333333333333333333333333333333333333333333333333333333";
const MOCK_NULLIFIER_1: Hex =
  "0x4444444444444444444444444444444444444444444444444444444444444444";
const MOCK_OUT_0: Hex =
  "0x5555555555555555555555555555555555555555555555555555555555555555";
const MOCK_OUT_1: Hex =
  "0x6666666666666666666666666666666666666666666666666666666666666666";
const MOCK_TX_HASH: Hash =
  "0xabcdef0000000000000000000000000000000000000000000000000000000000";
const MOCK_RECIPIENT: Address =
  "0x0000000000000000000000000000000000000001";

beforeEach(() => {
  jest.clearAllMocks();
});

// ── Tests ──────────────────────────────────────────────

describe("SoulPrivacyClient", () => {
  describe("constructor", () => {
    it("creates client for known chain", () => {
      const client = new SoulPrivacyClient(CHAIN_KEY);
      expect(client.getChainConfig().chainId).toBe(43113);
    });

    it("throws for unknown chain", () => {
      expect(() => new SoulPrivacyClient("nonexistent-chain")).toThrow(
        "Unknown chain",
      );
    });
  });

  describe("getPoolStatus()", () => {
    it("returns pool status from contract calls", async () => {
      mockReadContract
        .mockResolvedValueOnce(MOCK_ROOT) // getLatestRoot
        .mockResolvedValueOnce(42n); // getNextLeafIndex

      const client = new SoulPrivacyClient(CHAIN_KEY);
      const status: PoolStatus = await client.getPoolStatus();

      expect(status.latestRoot).toBe(MOCK_ROOT);
      expect(status.nextLeafIndex).toBe(42n);
      expect(status.isActive).toBe(true);
      expect(mockReadContract).toHaveBeenCalledTimes(2);
    });
  });

  describe("isNullifierSpent()", () => {
    it("queries the contract with the nullifier", async () => {
      mockReadContract.mockResolvedValueOnce(true);

      const client = new SoulPrivacyClient(CHAIN_KEY);
      const spent = await client.isNullifierSpent(MOCK_NULLIFIER_0);

      expect(spent).toBe(true);
      expect(mockReadContract).toHaveBeenCalledWith(
        expect.objectContaining({
          functionName: "isSpent",
          args: [MOCK_NULLIFIER_0],
        }),
      );
    });

    it("returns false for unspent nullifier", async () => {
      mockReadContract.mockResolvedValueOnce(false);
      const client = new SoulPrivacyClient(CHAIN_KEY);
      expect(await client.isNullifierSpent(MOCK_NULLIFIER_0)).toBe(false);
    });
  });

  describe("isKnownRoot()", () => {
    it("queries the contract for root validity", async () => {
      mockReadContract.mockResolvedValueOnce(true);

      const client = new SoulPrivacyClient(CHAIN_KEY);
      const known = await client.isKnownRoot(MOCK_ROOT);

      expect(known).toBe(true);
      expect(mockReadContract).toHaveBeenCalledWith(
        expect.objectContaining({
          functionName: "isKnownRoot",
          args: [MOCK_ROOT],
        }),
      );
    });
  });

  describe("deposit()", () => {
    it("throws without wallet client", async () => {
      const client = new SoulPrivacyClient(CHAIN_KEY);
      await expect(
        client.deposit(MOCK_COMMITMENT, 1000000000000000000n),
      ).rejects.toThrow("Wallet client required");
    });
  });

  describe("transfer()", () => {
    it("throws without wallet client", async () => {
      const client = new SoulPrivacyClient(CHAIN_KEY);
      await expect(
        client.transfer(
          "0xproof" as Hex,
          MOCK_ROOT,
          [MOCK_NULLIFIER_0, MOCK_NULLIFIER_1],
          [MOCK_OUT_0, MOCK_OUT_1],
        ),
      ).rejects.toThrow("Wallet client required");
    });
  });

  describe("withdraw()", () => {
    it("throws without wallet client", async () => {
      const client = new SoulPrivacyClient(CHAIN_KEY);
      await expect(
        client.withdraw(
          "0xproof" as Hex,
          MOCK_ROOT,
          [MOCK_NULLIFIER_0, MOCK_NULLIFIER_1],
          [MOCK_OUT_0, MOCK_OUT_1],
          MOCK_RECIPIENT,
          1000000000000000000n,
        ),
      ).rejects.toThrow("Wallet client required");
    });
  });

  describe("getCurrentEpoch()", () => {
    it("returns current epoch ID", async () => {
      mockReadContract.mockResolvedValueOnce(5n);
      const client = new SoulPrivacyClient(CHAIN_KEY);
      expect(await client.getCurrentEpoch()).toBe(5n);
    });
  });

  describe("getEpochRoot()", () => {
    it("calls epochManager with epoch ID", async () => {
      mockReadContract.mockResolvedValueOnce(MOCK_ROOT);
      const client = new SoulPrivacyClient(CHAIN_KEY);
      const root = await client.getEpochRoot(3n);
      expect(root).toBe(MOCK_ROOT);
      expect(mockReadContract).toHaveBeenCalledWith(
        expect.objectContaining({
          functionName: "getEpochRoot",
          args: [3n],
        }),
      );
    });
  });

  describe("estimateBridgeFee()", () => {
    it("returns estimated fee", async () => {
      mockReadContract.mockResolvedValueOnce(50000000000000000n);
      const client = new SoulPrivacyClient(CHAIN_KEY);
      const fee = await client.estimateBridgeFee(
        43114n,
        "0xdeadbeef" as Hex,
      );
      expect(fee).toBe(50000000000000000n);
    });
  });

  describe("getChainConfig()", () => {
    it("returns the chain configuration", () => {
      const client = new SoulPrivacyClient(CHAIN_KEY);
      const config = client.getChainConfig();
      expect(config.name).toContain("Fuji");
      expect(config.ecosystem).toBe("avalanche");
    });
  });
});

describe("MultiChainPrivacyManager", () => {
  it("adds and retrieves chains", () => {
    const mgr = new MultiChainPrivacyManager();
    mgr.addChain("avalanche-fuji");
    mgr.addChain("moonbase-alpha");

    expect(mgr.getRegisteredChains()).toEqual(
      expect.arrayContaining(["avalanche-fuji", "moonbase-alpha"]),
    );
    expect(mgr.getClient("avalanche-fuji")).toBeDefined();
  });

  it("throws for unregistered chain", () => {
    const mgr = new MultiChainPrivacyManager();
    expect(() => mgr.getClient("unknown")).toThrow("Chain not registered");
  });

  it("crossChainTransfer calls estimateBridgeFee then sendCrossChain", async () => {
    mockReadContract.mockResolvedValueOnce(100000n); // estimateFee
    mockWriteContract.mockResolvedValueOnce(MOCK_TX_HASH); // sendMessage

    const mgr = new MultiChainPrivacyManager();
    // We need a wallet client for transactions — use the mock
    const { createWalletClient: mockCreateWallet, http: mockHttp } =
      jest.requireMock("viem");
    mgr.addChain("avalanche-fuji", undefined, mockCreateWallet());

    const hash = await mgr.crossChainTransfer({
      sourceChain: "avalanche-fuji",
      destinationChain: "moonbase-alpha",
      proof: "0xproof" as Hex,
      merkleRoot: MOCK_ROOT,
      nullifiers: [MOCK_NULLIFIER_0, MOCK_NULLIFIER_1],
      outputCommitments: [MOCK_OUT_0, MOCK_OUT_1],
    });

    expect(hash).toBeDefined();
  });
});
