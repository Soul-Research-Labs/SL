import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Address,
  type Hash,
  type Hex,
  type Transport,
  encodeFunctionData,
  keccak256,
  encodePacked,
  parseEther,
} from "viem";

import { ALL_CHAINS, type ChainConfig } from "./chains";

// ── Private Mempool Configuration ──────────────────────

/**
 * Supported private mempool endpoints for MEV protection.
 * When configured, write transactions are routed through the private RPC
 * instead of the chain's public mempool.
 */
export interface PrivateMempoolConfig {
  /** Private RPC endpoint URL */
  rpcUrl: string;
  /** Provider identifier for diagnostics */
  provider: "flashbots" | "mev-blocker" | "custom";
}

// ── ABI Fragments ──────────────────────────────────────

const PRIVACY_POOL_ABI = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "commitment", type: "bytes32" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "transfer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "proof", type: "bytes" },
      { name: "merkleRoot", type: "bytes32" },
      { name: "nullifiers", type: "bytes32[2]" },
      { name: "outputCommitments", type: "bytes32[2]" },
      { name: "_domainChainId", type: "uint256" },
      { name: "_domainAppId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "withdraw",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "proof", type: "bytes" },
      { name: "merkleRoot", type: "bytes32" },
      { name: "nullifiers", type: "bytes32[2]" },
      { name: "outputCommitments", type: "bytes32[2]" },
      { name: "recipient", type: "address" },
      { name: "exitValue", type: "uint256" },
    ],
    outputs: [],
  },
  {
    name: "getLatestRoot",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    name: "isKnownRoot",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "root", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "isSpent",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "nullifierHash", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "getNextLeafIndex",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "commitDeposit",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "commitHash", type: "bytes32" }],
    outputs: [],
  },
  {
    name: "revealDeposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "commitment", type: "bytes32" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    name: "reclaimExpiredCommit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "commitHash", type: "bytes32" }],
    outputs: [],
  },
] as const;

const EPOCH_MANAGER_ABI = [
  {
    name: "currentEpochId",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "getEpochRoot",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "epochId", type: "uint256" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    name: "getRemoteEpochRoot",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "sourceChainId", type: "uint256" },
      { name: "epochId", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

const BRIDGE_ADAPTER_ABI = [
  {
    name: "sendMessage",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "destinationChainId", type: "uint256" },
      { name: "payload", type: "bytes" },
    ],
    outputs: [{ name: "messageId", type: "bytes32" }],
  },
  {
    name: "estimateFee",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "destinationChainId", type: "uint256" },
      { name: "payload", type: "bytes" },
    ],
    outputs: [{ name: "fee", type: "uint256" }],
  },
  {
    name: "isChainSupported",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "chainId", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "bridgeProtocol",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

// ── Proof Types ────────────────────────────────────────

export interface TransferProofInput {
  inputNotes: [Hex, Hex];
  spendingKeys: [Hex, Hex];
  outputRecipients: [Hex, Hex];
  outputValues: [bigint, bigint];
  outputBlindings: [Hex, Hex];
}

export interface WithdrawProofInput {
  inputNotes: [Hex, Hex];
  spendingKeys: [Hex, Hex];
  changeRecipient: Hex;
  changeValue: bigint;
  changeBlinding: Hex;
  exitValue: bigint;
}

export interface PoolStatus {
  latestRoot: Hex;
  nextLeafIndex: bigint;
  isActive: boolean;
}

export interface CrossChainTransferParams {
  sourceChain: string;
  destinationChain: string;
  proof: Hex;
  merkleRoot: Hex;
  nullifiers: [Hex, Hex];
  outputCommitments: [Hex, Hex];
}

// ── Client ─────────────────────────────────────────────

export class SoulPrivacyClient {
  private publicClient: PublicClient;
  private walletClient?: WalletClient;
  private privateWalletClient?: WalletClient;
  private chainConfig: ChainConfig;
  private privateMempoolConfig?: PrivateMempoolConfig;

  constructor(
    chainKey: string,
    rpcUrl?: string,
    walletClient?: WalletClient,
    privateMempool?: PrivateMempoolConfig,
  ) {
    const config = ALL_CHAINS[chainKey];
    if (!config) {
      throw new Error(
        `Unknown chain: ${chainKey}. Available: ${Object.keys(ALL_CHAINS).join(", ")}`,
      );
    }
    this.chainConfig = config;
    this.walletClient = walletClient;
    this.privateMempoolConfig = privateMempool;

    const viemChain: Chain = {
      id: config.chainId,
      name: config.name,
      nativeCurrency: {
        name: config.nativeToken,
        symbol: config.nativeToken,
        decimals: 18,
      },
      rpcUrls: {
        default: { http: [rpcUrl || config.rpcUrl] },
      },
    };

    this.publicClient = createPublicClient({
      chain: viemChain,
      transport: http(rpcUrl || config.rpcUrl),
    });

    // When a private mempool is configured, create a separate wallet client
    // that routes write transactions through the private RPC to avoid MEV.
    if (privateMempool && walletClient) {
      this.privateWalletClient = createWalletClient({
        chain: viemChain,
        transport: http(privateMempool.rpcUrl),
        account: walletClient.account,
      });
    }
  }

  /**
   * Returns the wallet client to use for write operations. When a private
   * mempool is configured, transactions are routed through the private RPC
   * to prevent front-running and sandwich attacks.
   */
  private getWriteClient(): WalletClient {
    if (!this.walletClient)
      throw new Error("Wallet client required for transactions");
    return this.privateWalletClient ?? this.walletClient;
  }

  // ── Pool Queries ───────────────────────────────────

  async getPoolStatus(): Promise<PoolStatus> {
    const [root, nextIndex] = await Promise.all([
      this.publicClient.readContract({
        address: this.chainConfig.contracts.privacyPool as Address,
        abi: PRIVACY_POOL_ABI,
        functionName: "getLatestRoot",
      }),
      this.publicClient.readContract({
        address: this.chainConfig.contracts.privacyPool as Address,
        abi: PRIVACY_POOL_ABI,
        functionName: "getNextLeafIndex",
      }),
    ]);

    return {
      latestRoot: root as Hex,
      nextLeafIndex: nextIndex as bigint,
      isActive: true,
    };
  }

  async isNullifierSpent(nullifier: Hex): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "isSpent",
      args: [nullifier],
    }) as Promise<boolean>;
  }

  async isKnownRoot(root: Hex): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "isKnownRoot",
      args: [root],
    }) as Promise<boolean>;
  }

  // ── Transactions ───────────────────────────────────

  async deposit(commitment: Hex, amount: bigint): Promise<Hash> {
    const client = this.getWriteClient();

    const hash = await client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "deposit",
      args: [commitment, amount],
      value: amount,
    });

    return hash;
  }

  // ── Commit-Reveal Deposit (MEV Protected) ──────────

  /**
   * Phase 1: submit a hidden commit for a future deposit.
   * The commitment is hidden behind keccak256(commitment, salt).
   * After MIN_COMMIT_DELAY blocks, call {@link revealDeposit}.
   */
  async commitDeposit(
    commitment: Hex,
    salt: Hex,
    amount: bigint,
  ): Promise<{ hash: Hash; commitHash: Hex }> {
    const client = this.getWriteClient();
    const commitHash = keccak256(
      encodePacked(["bytes32", "bytes32"], [commitment, salt]),
    );

    const hash = await client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "commitDeposit",
      args: [commitHash],
      value: amount,
    });

    return { hash, commitHash };
  }

  /**
   * Phase 2: reveal the commitment from a previous commit. Must be called
   * between MIN_COMMIT_DELAY (2 blocks) and MAX_COMMIT_DELAY (100 blocks)
   * after the commit transaction.
   */
  async revealDeposit(commitment: Hex, salt: Hex): Promise<Hash> {
    const client = this.getWriteClient();
    return client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "revealDeposit",
      args: [commitment, salt],
    });
  }

  /**
   * Reclaim funds from an expired commit (>MAX_COMMIT_DELAY blocks old).
   */
  async reclaimExpiredCommit(commitHash: Hex): Promise<Hash> {
    const client = this.getWriteClient();
    return client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "reclaimExpiredCommit",
      args: [commitHash],
    });
  }

  async transfer(
    proof: Hex,
    merkleRoot: Hex,
    nullifiers: [Hex, Hex],
    outputCommitments: [Hex, Hex],
    domainChainId?: bigint,
    domainAppId?: bigint,
  ): Promise<Hash> {
    const client = this.getWriteClient();

    return client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "transfer",
      args: [
        proof,
        merkleRoot,
        nullifiers,
        outputCommitments,
        domainChainId ?? BigInt(this.chainConfig.chainId),
        domainAppId ?? 1n,
      ],
    });
  }

  async withdraw(
    proof: Hex,
    merkleRoot: Hex,
    nullifiers: [Hex, Hex],
    outputCommitments: [Hex, Hex],
    recipient: Address,
    exitValue: bigint,
  ): Promise<Hash> {
    const client = this.getWriteClient();

    return client.writeContract({
      address: this.chainConfig.contracts.privacyPool as Address,
      abi: PRIVACY_POOL_ABI,
      functionName: "withdraw",
      args: [
        proof,
        merkleRoot,
        nullifiers,
        outputCommitments,
        recipient,
        exitValue,
      ],
    });
  }

  // ── Epoch ──────────────────────────────────────────

  async getCurrentEpoch(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.chainConfig.contracts.epochManager as Address,
      abi: EPOCH_MANAGER_ABI,
      functionName: "currentEpochId",
    }) as Promise<bigint>;
  }

  async getEpochRoot(epochId: bigint): Promise<Hex> {
    return this.publicClient.readContract({
      address: this.chainConfig.contracts.epochManager as Address,
      abi: EPOCH_MANAGER_ABI,
      functionName: "getEpochRoot",
      args: [epochId],
    }) as Promise<Hex>;
  }

  async getRemoteEpochRoot(
    sourceChainId: bigint,
    epochId: bigint,
  ): Promise<Hex> {
    return this.publicClient.readContract({
      address: this.chainConfig.contracts.epochManager as Address,
      abi: EPOCH_MANAGER_ABI,
      functionName: "getRemoteEpochRoot",
      args: [sourceChainId, epochId],
    }) as Promise<Hex>;
  }

  // ── Cross-Chain ────────────────────────────────────

  async estimateBridgeFee(
    destinationChainId: bigint,
    payload: Hex,
  ): Promise<bigint> {
    const adapter = this.chainConfig.contracts.bridgeAdapter;
    if (!adapter)
      throw new Error("No bridge adapter configured for this chain");

    return this.publicClient.readContract({
      address: adapter as Address,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "estimateFee",
      args: [destinationChainId, payload],
    }) as Promise<bigint>;
  }

  async sendCrossChain(
    destinationChainId: bigint,
    payload: Hex,
    fee: bigint,
  ): Promise<Hash> {
    const client = this.getWriteClient();
    const adapter = this.chainConfig.contracts.bridgeAdapter;
    if (!adapter)
      throw new Error("No bridge adapter configured for this chain");

    return client.writeContract({
      address: adapter as Address,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "sendMessage",
      args: [destinationChainId, payload],
      value: fee,
    });
  }

  async isDestinationSupported(destinationChainId: bigint): Promise<boolean> {
    const adapter = this.chainConfig.contracts.bridgeAdapter;
    if (!adapter) return false;

    return this.publicClient.readContract({
      address: adapter as Address,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "isChainSupported",
      args: [destinationChainId],
    }) as Promise<boolean>;
  }

  async getBridgeProtocol(): Promise<string> {
    const adapter = this.chainConfig.contracts.bridgeAdapter;
    if (!adapter) return "none";

    return this.publicClient.readContract({
      address: adapter as Address,
      abi: BRIDGE_ADAPTER_ABI,
      functionName: "bridgeProtocol",
    }) as Promise<string>;
  }

  // ── Config ─────────────────────────────────────────

  getChainConfig(): ChainConfig {
    return this.chainConfig;
  }
}

// ── Multi-Chain Manager ────────────────────────────────

export class MultiChainPrivacyManager {
  private clients: Map<string, SoulPrivacyClient> = new Map();

  addChain(
    chainKey: string,
    rpcUrl?: string,
    walletClient?: WalletClient,
    privateMempool?: PrivateMempoolConfig,
  ): void {
    this.clients.set(
      chainKey,
      new SoulPrivacyClient(chainKey, rpcUrl, walletClient, privateMempool),
    );
  }

  getClient(chainKey: string): SoulPrivacyClient {
    const client = this.clients.get(chainKey);
    if (!client) throw new Error(`Chain not registered: ${chainKey}`);
    return client;
  }

  async crossChainTransfer(params: CrossChainTransferParams): Promise<Hash> {
    const sourceClient = this.getClient(params.sourceChain);
    const destConfig = ALL_CHAINS[params.destinationChain];
    if (!destConfig)
      throw new Error(`Unknown destination: ${params.destinationChain}`);

    // Encode the transfer payload for bridge — including domain IDs
    const payload = encodeFunctionData({
      abi: PRIVACY_POOL_ABI,
      functionName: "transfer",
      args: [
        params.proof,
        params.merkleRoot,
        params.nullifiers,
        params.outputCommitments,
        BigInt(destConfig.chainId),
        1n,
      ],
    });

    const fee = await sourceClient.estimateBridgeFee(
      BigInt(destConfig.chainId),
      payload,
    );
    return sourceClient.sendCrossChain(
      BigInt(destConfig.chainId),
      payload,
      fee,
    );
  }

  getRegisteredChains(): string[] {
    return Array.from(this.clients.keys());
  }
}

// ── Well-Known Private Mempool Presets ─────────────────

/** Flashbots Protect — Ethereum mainnet only. */
export const FLASHBOTS_PROTECT: PrivateMempoolConfig = {
  rpcUrl: "https://rpc.flashbots.net",
  provider: "flashbots",
};

/** MEV Blocker by CoW Protocol — Ethereum mainnet. */
export const MEV_BLOCKER: PrivateMempoolConfig = {
  rpcUrl: "https://rpc.mevblocker.io",
  provider: "mev-blocker",
};
