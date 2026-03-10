import {
  createPublicClient,
  http,
  type PublicClient,
  type Address,
  type Hex,
  formatEther,
  parseEther,
} from "viem";

import type { ChainConfig } from "./chains";

// ── Types ──────────────────────────────────────────────

export interface FeeEstimate {
  /** Total fee in wei (relayer gas + protocol fee + priority tip) */
  totalFeeWei: bigint;
  /** Total fee in native token (human-readable string) */
  totalFeeFormatted: string;
  /** Breakdown: estimated gas cost in wei */
  gasCostWei: bigint;
  /** Breakdown: protocol base fee in wei */
  protocolFeeWei: bigint;
  /** Breakdown: relayer priority tip in wei */
  relayerTipWei: bigint;
  /** Estimated gas units for the withdraw tx */
  gasEstimate: bigint;
  /** Gas price used for estimation (wei) */
  gasPriceWei: bigint;
  /** Effective net withdrawal after fee (exitValue - totalFee) */
  netWithdrawalWei: bigint;
  /** Whether the withdrawal is economical (net > 0 and fee < 50% of exit) */
  isEconomical: boolean;
}

export interface FeeEstimatorConfig {
  /** RPC URL override (defaults to chain config) */
  rpcUrl?: string;
  /** Relayer fee vault address (for on-chain fee lookup) */
  relayerFeeVault?: Address;
  /** Static protocol fee in basis points (default: 30 = 0.3%) */
  protocolFeeBps?: number;
  /** Relayer tip multiplier over base gas cost (default: 1.1 = 10% tip) */
  relayerTipMultiplier?: number;
  /** Fixed gas override (skip estimation) */
  gasOverride?: bigint;
}

// ── Constants ──────────────────────────────────────────

const DEFAULT_WITHDRAW_GAS = 350_000n;
const DEFAULT_PROTOCOL_FEE_BPS = 30n; // 0.3%
const BPS_DENOMINATOR = 10_000n;
const DEFAULT_TIP_MULTIPLIER = 110n; // 1.10x (110/100)
const TIP_DENOMINATOR = 100n;

// ── ABI fragment for RelayerFeeVault ───────────────────

const FEE_VAULT_ABI = [
  {
    name: "currentFee",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// ── Fee Estimator ──────────────────────────────────────

export class FeeEstimator {
  private client: PublicClient;
  private protocolFeeBps: bigint;
  private tipMultiplier: bigint;
  private gasOverride?: bigint;
  private feeVaultAddress?: Address;

  constructor(chain: ChainConfig, config: FeeEstimatorConfig = {}) {
    this.client = createPublicClient({
      transport: http(config.rpcUrl ?? chain.rpcUrl),
    });
    this.protocolFeeBps = BigInt(config.protocolFeeBps ?? 30);
    this.tipMultiplier = BigInt(
      Math.round((config.relayerTipMultiplier ?? 1.1) * 100),
    );
    this.gasOverride = config.gasOverride;
    this.feeVaultAddress = config.relayerFeeVault;
  }

  /**
   * Estimate the total fee for a withdrawal.
   *
   * @param exitValue The withdrawal amount in wei.
   * @returns Detailed fee breakdown.
   */
  async estimateWithdrawFee(exitValue: bigint): Promise<FeeEstimate> {
    // 1. Gas estimation
    const gasEstimate = this.gasOverride ?? DEFAULT_WITHDRAW_GAS;

    // 2. Current gas price
    const gasPriceWei = await this.client.getGasPrice();

    // 3. Gas cost
    const gasCostWei = gasEstimate * gasPriceWei;

    // 4. Relayer tip (percentage on top of gas cost)
    const relayerTipWei =
      (gasCostWei * this.tipMultiplier) / TIP_DENOMINATOR - gasCostWei;

    // 5. Protocol fee (percentage of exit value)
    let protocolFeeWei: bigint;
    if (this.feeVaultAddress) {
      try {
        protocolFeeWei = (await this.client.readContract({
          address: this.feeVaultAddress,
          abi: FEE_VAULT_ABI,
          functionName: "currentFee",
        })) as bigint;
      } catch {
        protocolFeeWei = (exitValue * this.protocolFeeBps) / BPS_DENOMINATOR;
      }
    } else {
      protocolFeeWei = (exitValue * this.protocolFeeBps) / BPS_DENOMINATOR;
    }

    // 6. Total
    const totalFeeWei = gasCostWei + relayerTipWei + protocolFeeWei;
    const netWithdrawalWei =
      exitValue > totalFeeWei ? exitValue - totalFeeWei : 0n;

    // Economical if fee < 50% of exit value and net > 0
    const isEconomical = netWithdrawalWei > 0n && totalFeeWei * 2n < exitValue;

    return {
      totalFeeWei,
      totalFeeFormatted: formatEther(totalFeeWei),
      gasCostWei,
      protocolFeeWei,
      relayerTipWei,
      gasEstimate,
      gasPriceWei,
      netWithdrawalWei,
      isEconomical,
    };
  }

  /**
   * Quick check: is a withdrawal of this size worth it?
   */
  async isWithdrawalEconomical(exitValue: bigint): Promise<boolean> {
    const est = await this.estimateWithdrawFee(exitValue);
    return est.isEconomical;
  }

  /**
   * Calculate the minimum withdrawal amount that is economical
   * at current gas prices.
   */
  async minimumEconomicalWithdrawal(): Promise<bigint> {
    // Use a reference amount to get base gas cost
    const refAmount = parseEther("1");
    const est = await this.estimateWithdrawFee(refAmount);

    // Minimum = gasCost + tip must be < 50% of exit
    // So exit > 2 * (gasCost + tip)
    // Adding protocol fee: exit > 2 * (gasCost + tip) / (1 - 2 * protocolBps/10000)
    const gasAndTip = est.gasCostWei + est.relayerTipWei;
    const denominator = BPS_DENOMINATOR - 2n * this.protocolFeeBps;

    if (denominator <= 0n) {
      // Protocol fee is >= 50%, never economical
      return 0n;
    }

    return (gasAndTip * 2n * BPS_DENOMINATOR) / denominator;
  }
}
