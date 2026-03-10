import { FeeEstimator, type FeeEstimate } from "../fees";
import type { ChainConfig } from "../chains";

// ── Mock viem ──────────────────────────────────────────

const mockGetGasPrice = jest.fn<Promise<bigint>, []>();
const mockReadContract = jest.fn();

jest.mock("viem", () => ({
  createPublicClient: () => ({
    getGasPrice: mockGetGasPrice,
    readContract: mockReadContract,
  }),
  http: () => ({}),
  formatEther: (wei: bigint) => {
    const str = wei.toString();
    if (str.length <= 18) return "0." + str.padStart(18, "0");
    return str.slice(0, str.length - 18) + "." + str.slice(str.length - 18);
  },
  parseEther: (val: string) => BigInt(val) * 10n ** 18n,
}));

// ── Fixtures ───────────────────────────────────────────

const CHAIN: ChainConfig = {
  name: "Avalanche C-Chain",
  chainId: 43114,
  rpcUrl: "https://api.avax.network/ext/bc/C/rpc",
  ecosystem: "avalanche",
  contracts: {
    privacyPool: "0x0000000000000000000000000000000000000001" as `0x${string}`,
    verifier: "0x0000000000000000000000000000000000000002" as `0x${string}`,
    epochManager: "0x0000000000000000000000000000000000000003" as `0x${string}`,
  },
} as ChainConfig;

const ONE_ETH = 10n ** 18n;
const GAS_PRICE = 25_000_000_000n; // 25 gwei

beforeEach(() => {
  jest.clearAllMocks();
  mockGetGasPrice.mockResolvedValue(GAS_PRICE);
});

// ── Tests ──────────────────────────────────────────────

describe("FeeEstimator", () => {
  describe("estimateWithdrawFee()", () => {
    it("returns correct fee breakdown with defaults", async () => {
      const estimator = new FeeEstimator(CHAIN);
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);

      // Default gas: 350_000, gasPrice: 25 gwei → gasCost = 8.75e15
      const expectedGas = 350_000n * GAS_PRICE;
      expect(fee.gasCostWei).toBe(expectedGas);
      expect(fee.gasEstimate).toBe(350_000n);
      expect(fee.gasPriceWei).toBe(GAS_PRICE);

      // Tip: 10% of gas cost
      const expectedTip = (expectedGas * 110n) / 100n - expectedGas;
      expect(fee.relayerTipWei).toBe(expectedTip);

      // Protocol fee: 0.3% of 1 ETH
      const expectedProtocol = (ONE_ETH * 30n) / 10_000n;
      expect(fee.protocolFeeWei).toBe(expectedProtocol);

      // Total
      const expectedTotal = expectedGas + expectedTip + expectedProtocol;
      expect(fee.totalFeeWei).toBe(expectedTotal);

      // Net
      expect(fee.netWithdrawalWei).toBe(ONE_ETH - expectedTotal);
      expect(fee.isEconomical).toBe(true);
    });

    it("respects gasOverride", async () => {
      const estimator = new FeeEstimator(CHAIN, { gasOverride: 500_000n });
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);
      expect(fee.gasEstimate).toBe(500_000n);
      expect(fee.gasCostWei).toBe(500_000n * GAS_PRICE);
    });

    it("respects custom protocolFeeBps", async () => {
      const estimator = new FeeEstimator(CHAIN, { protocolFeeBps: 100 }); // 1%
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);
      expect(fee.protocolFeeWei).toBe(ONE_ETH / 100n);
    });

    it("respects custom relayerTipMultiplier", async () => {
      const estimator = new FeeEstimator(CHAIN, { relayerTipMultiplier: 1.5 });
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);
      const gasCost = 350_000n * GAS_PRICE;
      // 1.5x → multiplier = 150, tip = (gasCost*150/100) - gasCost = gasCost * 0.5
      const expectedTip = (gasCost * 150n) / 100n - gasCost;
      expect(fee.relayerTipWei).toBe(expectedTip);
    });

    it("marks small withdrawal as not economical", async () => {
      const estimator = new FeeEstimator(CHAIN);
      // Very small amount — fee > 50%
      const fee = await estimator.estimateWithdrawFee(1000n);
      expect(fee.isEconomical).toBe(false);
      expect(fee.netWithdrawalWei).toBe(0n);
    });

    it("uses on-chain fee from vault when configured", async () => {
      const vaultFee = ONE_ETH / 200n; // 0.5%
      mockReadContract.mockResolvedValue(vaultFee);

      const estimator = new FeeEstimator(CHAIN, {
        relayerFeeVault:
          "0x000000000000000000000000000000000000dead" as `0x${string}`,
      });
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);
      expect(fee.protocolFeeWei).toBe(vaultFee);
      expect(mockReadContract).toHaveBeenCalledTimes(1);
    });

    it("falls back to BPS fee if vault call fails", async () => {
      mockReadContract.mockRejectedValue(new Error("revert"));

      const estimator = new FeeEstimator(CHAIN, {
        relayerFeeVault:
          "0x000000000000000000000000000000000000dead" as `0x${string}`,
      });
      const fee = await estimator.estimateWithdrawFee(ONE_ETH);
      expect(fee.protocolFeeWei).toBe((ONE_ETH * 30n) / 10_000n);
    });
  });

  describe("isWithdrawalEconomical()", () => {
    it("returns true for large amounts", async () => {
      const estimator = new FeeEstimator(CHAIN);
      const result = await estimator.isWithdrawalEconomical(ONE_ETH);
      expect(result).toBe(true);
    });

    it("returns false for dust amounts", async () => {
      const estimator = new FeeEstimator(CHAIN);
      const result = await estimator.isWithdrawalEconomical(100n);
      expect(result).toBe(false);
    });
  });

  describe("minimumEconomicalWithdrawal()", () => {
    it("returns a value that makes withdrawal economical", async () => {
      const estimator = new FeeEstimator(CHAIN);
      const minAmount = await estimator.minimumEconomicalWithdrawal();

      expect(minAmount).toBeGreaterThan(0n);

      // Verify that this amount is actually economical
      const fee = await estimator.estimateWithdrawFee(minAmount);
      // The minimum should be right at the boundary — net >= 0 and fee < 50%
      expect(fee.totalFeeWei * 2n).toBeLessThanOrEqual(minAmount);
    });
  });
});
