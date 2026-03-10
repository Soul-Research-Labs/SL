// Re-export enhanced client
export {
  SoulPrivacyClient as SoulPrivacyClientV2,
  MultiChainPrivacyManager,
} from "./client";
export type {
  TransferProofInput,
  WithdrawProofInput,
  PoolStatus,
  CrossChainTransferParams,
} from "./client";
export {
  ALL_CHAINS,
  getChainByChainId,
  getChainsByEcosystem,
  getTestnetChains,
} from "./chains/index";
export type { ChainConfig, ChainContracts } from "./chains/index";
export {
  findRoutes,
  findOptimalRoute,
  isNullifierSpentAnywhere,
  getGlobalPoolStatus,
  shieldedCrossChainTransfer,
  BRIDGE_TOPOLOGY,
} from "./router";
export type {
  BridgeEdge,
  Route,
  GlobalPoolStatus,
  ShieldedCrossChainParams,
} from "./router";
export { NoteWallet } from "./wallet";
export type {
  ShieldedNote,
  SpendParams,
  StealthMetaAddress,
  EncryptedNoteBackup,
} from "./wallet";
export {
  generateEphemeralKeyPair,
  computeSharedSecret,
  deriveStealthAddress,
  computeViewTag,
  createStealthAnnouncement,
  scanAnnouncement,
  scanAnnouncementBatch,
} from "./stealth";
export type {
  EphemeralKeyPair,
  StealthAnnouncement,
  ScanResult,
} from "./stealth";
export { ProofClient } from "./prover";
export type {
  ProofType,
  ProofRequest,
  ProofResult,
  DepositProofRequest,
  TransferProofRequest,
  WithdrawProofRequest,
  CoprocessorHealth,
  ProofClientConfig,
} from "./prover";
export { FeeEstimator } from "./fees";
export type { FeeEstimate, FeeEstimatorConfig } from "./fees";
export { SubgraphClient } from "./subgraph";
export type {
  SubgraphConfig,
  DepositEntity,
  TransferEntity,
  WithdrawalEntity,
  EpochEntity,
  PoolMetricsEntity,
  TimelockTransactionEntity,
  PaginationOpts,
} from "./subgraph";

// Legacy client (kept for backward compatibility)
import {
  createPublicClient,
  createWalletClient,
  http,
  type Chain,
  type PublicClient,
  type WalletClient,
  type Transport,
  type Account,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { ChainConfig, ChainContracts } from "./chains/index";

// ── ABI fragments (minimal — extend from compiled artifacts) ─────────

const PRIVACY_POOL_ABI = [
  {
    type: "function",
    name: "deposit",
    inputs: [
      { name: "commitment", type: "bytes32" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "transfer",
    inputs: [
      { name: "proof", type: "bytes" },
      { name: "merkleRoot", type: "bytes32" },
      { name: "nullifiers", type: "bytes32[2]" },
      { name: "outputCommitments", type: "bytes32[2]" },
      { name: "domainChainId", type: "uint256" },
      { name: "domainAppId", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "withdraw",
    inputs: [
      { name: "proof", type: "bytes" },
      { name: "merkleRoot", type: "bytes32" },
      { name: "nullifiers", type: "bytes32[2]" },
      { name: "outputCommitments", type: "bytes32[2]" },
      { name: "recipient", type: "address" },
      { name: "exitValue", type: "uint256" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "getLatestRoot",
    inputs: [],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getPoolBalance",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isSpent",
    inputs: [{ name: "nullifier", type: "bytes32" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getNextLeafIndex",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

const EPOCH_MANAGER_ABI = [
  {
    type: "function",
    name: "getCurrentEpochId",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getEpochRoot",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getRemoteEpochRoot",
    inputs: [
      { name: "sourceChainId", type: "uint256" },
      { name: "epochId", type: "uint256" },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

const BRIDGE_ADAPTER_ABI = [
  {
    type: "function",
    name: "sendMessage",
    inputs: [
      { name: "destinationChainId", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "payload", type: "bytes" },
      { name: "gasLimit", type: "uint256" },
    ],
    outputs: [{ type: "bytes32" }],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "estimateFee",
    inputs: [
      { name: "destinationChainId", type: "uint256" },
      { name: "payload", type: "bytes" },
      { name: "gasLimit", type: "uint256" },
    ],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "isChainSupported",
    inputs: [{ name: "chainId", type: "uint256" }],
    outputs: [{ type: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "bridgeProtocol",
    inputs: [],
    outputs: [{ type: "string" }],
    stateMutability: "pure",
  },
] as const;

// ── SDK Types ────────────────────────────────────────────────────────

export interface SoulPrivacyConfig {
  chain: ChainConfig;
  privateKey?: `0x${string}`;
}

export interface PoolStatus {
  balance: bigint;
  latestRoot: `0x${string}`;
  nextLeafIndex: bigint;
  currentEpochId: bigint;
}

export interface ShieldedTransferParams {
  fromChain: string;
  toChain: string;
  amount: bigint;
  proof: `0x${string}`;
  nullifiers: [`0x${string}`, `0x${string}`];
  outputCommitments: [`0x${string}`, `0x${string}`];
}

export interface DepositParams {
  commitment: `0x${string}`;
  amount: bigint;
}

export interface WithdrawParams {
  proof: `0x${string}`;
  merkleRoot: `0x${string}`;
  nullifiers: [`0x${string}`, `0x${string}`];
  outputCommitments: [`0x${string}`, `0x${string}`];
  recipient: `0x${string}`;
  exitValue: bigint;
}

// ── SDK Client ───────────────────────────────────────────────────────

export class SoulPrivacyClient {
  private publicClient: PublicClient;
  private walletClient: WalletClient | null = null;
  private chain: ChainConfig;
  private contracts: ChainContracts;

  constructor(config: SoulPrivacyConfig) {
    this.chain = config.chain;
    this.contracts = config.chain.contracts;

    // Build viem chain object
    const viemChain: Chain = {
      id: config.chain.chainId,
      name: config.chain.name,
      nativeCurrency: {
        name: config.chain.nativeToken,
        symbol: config.chain.nativeToken,
        decimals: 18,
      },
      rpcUrls: {
        default: { http: [config.chain.rpcUrl] },
      },
    };

    this.publicClient = createPublicClient({
      chain: viemChain,
      transport: http(config.chain.rpcUrl),
    });

    if (config.privateKey) {
      const account = privateKeyToAccount(config.privateKey);
      this.walletClient = createWalletClient({
        account,
        chain: viemChain,
        transport: http(config.chain.rpcUrl),
      });
    }
  }

  // ── Pool Status ──────────────────────────────────────────────────

  async getPoolStatus(): Promise<PoolStatus> {
    const [balance, latestRoot, nextLeafIndex, currentEpochId] =
      await Promise.all([
        this.publicClient.readContract({
          address: this.contracts.privacyPool as `0x${string}`,
          abi: PRIVACY_POOL_ABI,
          functionName: "getPoolBalance",
        }),
        this.publicClient.readContract({
          address: this.contracts.privacyPool as `0x${string}`,
          abi: PRIVACY_POOL_ABI,
          functionName: "getLatestRoot",
        }),
        this.publicClient.readContract({
          address: this.contracts.privacyPool as `0x${string}`,
          abi: PRIVACY_POOL_ABI,
          functionName: "getNextLeafIndex",
        }),
        this.publicClient.readContract({
          address: this.contracts.epochManager as `0x${string}`,
          abi: EPOCH_MANAGER_ABI,
          functionName: "getCurrentEpochId",
        }),
      ]);

    return {
      balance: balance as bigint,
      latestRoot: latestRoot as `0x${string}`,
      nextLeafIndex: nextLeafIndex as bigint,
      currentEpochId: currentEpochId as bigint,
    };
  }

  // ── Deposit ──────────────────────────────────────────────────────

  async deposit(params: DepositParams): Promise<`0x${string}`> {
    if (!this.walletClient) throw new Error("Wallet not configured");

    const hash = await this.walletClient.writeContract({
      address: this.contracts.privacyPool as `0x${string}`,
      abi: PRIVACY_POOL_ABI,
      functionName: "deposit",
      args: [params.commitment, params.amount],
      value: params.amount,
    });

    return hash;
  }

  // ── Withdraw ─────────────────────────────────────────────────────

  async withdraw(params: WithdrawParams): Promise<`0x${string}`> {
    if (!this.walletClient) throw new Error("Wallet not configured");

    const hash = await this.walletClient.writeContract({
      address: this.contracts.privacyPool as `0x${string}`,
      abi: PRIVACY_POOL_ABI,
      functionName: "withdraw",
      args: [
        params.proof,
        params.merkleRoot,
        params.nullifiers,
        params.outputCommitments,
        params.recipient,
        params.exitValue,
      ],
    });

    return hash;
  }

  // ── Nullifier Check ──────────────────────────────────────────────

  async isNullifierSpent(nullifier: `0x${string}`): Promise<boolean> {
    const result = await this.publicClient.readContract({
      address: this.contracts.privacyPool as `0x${string}`,
      abi: PRIVACY_POOL_ABI,
      functionName: "isSpent",
      args: [nullifier],
    });
    return result as boolean;
  }

  // ── Cross-Chain: Bridge ──────────────────────────────────────────

  async estimateBridgeFee(
    destinationChainId: number,
    payload: `0x${string}`,
    gasLimit: bigint = 300000n,
  ): Promise<bigint> {
    const fee = await this.publicClient.readContract({
      address: this.contracts.bridgeAdapter as `0x${string}`,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "estimateFee",
      args: [BigInt(destinationChainId), payload, gasLimit],
    });
    return fee as bigint;
  }

  async sendCrossChain(
    destinationChainId: number,
    recipient: `0x${string}`,
    payload: `0x${string}`,
    gasLimit: bigint = 300000n,
  ): Promise<`0x${string}`> {
    if (!this.walletClient) throw new Error("Wallet not configured");

    const fee = await this.estimateBridgeFee(
      destinationChainId,
      payload,
      gasLimit,
    );

    const hash = await this.walletClient.writeContract({
      address: this.contracts.bridgeAdapter as `0x${string}`,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "sendMessage",
      args: [BigInt(destinationChainId), recipient, payload, gasLimit],
      value: fee,
    });

    return hash;
  }

  // ── Epoch Roots ──────────────────────────────────────────────────

  async getEpochRoot(epochId: bigint): Promise<`0x${string}`> {
    const root = await this.publicClient.readContract({
      address: this.contracts.epochManager as `0x${string}`,
      abi: EPOCH_MANAGER_ABI,
      functionName: "getEpochRoot",
      args: [epochId],
    });
    return root as `0x${string}`;
  }

  async getRemoteEpochRoot(
    sourceChainId: number,
    epochId: bigint,
  ): Promise<`0x${string}`> {
    const root = await this.publicClient.readContract({
      address: this.contracts.epochManager as `0x${string}`,
      abi: EPOCH_MANAGER_ABI,
      functionName: "getRemoteEpochRoot",
      args: [BigInt(sourceChainId), epochId],
    });
    return root as `0x${string}`;
  }

  // ── Bridge Info ──────────────────────────────────────────────────

  async getBridgeProtocol(): Promise<string> {
    const protocol = await this.publicClient.readContract({
      address: this.contracts.bridgeAdapter as `0x${string}`,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "bridgeProtocol",
    });
    return protocol as string;
  }

  async isDestinationSupported(chainId: number): Promise<boolean> {
    const supported = await this.publicClient.readContract({
      address: this.contracts.bridgeAdapter as `0x${string}`,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "isChainSupported",
      args: [BigInt(chainId)],
    });
    return supported as boolean;
  }

  // ── Getters ──────────────────────────────────────────────────────

  getChainConfig(): ChainConfig {
    return this.chain;
  }

  getPublicClient(): PublicClient {
    return this.publicClient;
  }
}

// ── Re-exports ───────────────────────────────────────────────────────
export * from "./chains/index";
