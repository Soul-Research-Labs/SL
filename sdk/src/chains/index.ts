// ── Chain Definitions ─────────────────────────────────────────────────
// Each supported chain has its configuration, contract addresses, and bridge info.

export interface ChainConfig {
  /** Human readable name */
  name: string;
  /** EVM chain ID */
  chainId: number;
  /** RPC endpoint */
  rpcUrl: string;
  /** Block explorer URL */
  explorerUrl: string;
  /** Bridge protocol used on this chain */
  bridgeProtocol: "AWM" | "Teleporter" | "XCM" | "IBC" | "RainbowBridge";
  /** Ecosystem family */
  ecosystem: "avalanche" | "polkadot" | "cosmos" | "near";
  /** Native token symbol */
  nativeToken: string;
  /** Average block time in ms */
  blockTimeMs: number;
  /** Deployed contract addresses (populated after deployment) */
  contracts: ChainContracts;
  /** Extra metadata */
  meta: Record<string, string | number>;
}

export interface ChainContracts {
  privacyPool: string;
  epochManager: string;
  proofVerifier: string;
  bridgeAdapter: string;
}

// ── Zero addresses (pre-deployment placeholder) ──────────────────────
const ZERO: ChainContracts = {
  privacyPool: "0x0000000000000000000000000000000000000000",
  epochManager: "0x0000000000000000000000000000000000000000",
  proofVerifier: "0x0000000000000000000000000000000000000000",
  bridgeAdapter: "0x0000000000000000000000000000000000000000",
};

// ══════════════════════════════════════════════════════════════════════
//  AVALANCHE ECOSYSTEM
// ══════════════════════════════════════════════════════════════════════

export const AVALANCHE_FUJI: ChainConfig = {
  name: "Avalanche Fuji C-Chain",
  chainId: 43113,
  rpcUrl: "https://api.avax-test.network/ext/bc/C/rpc",
  explorerUrl: "https://testnet.snowtrace.io",
  bridgeProtocol: "Teleporter",
  ecosystem: "avalanche",
  nativeToken: "AVAX",
  blockTimeMs: 2000,
  contracts: { ...ZERO },
  meta: {
    blockchainID:
      "0x7fc93d85c6d62c5b2ac0b519c87010ea5294012d1e407030d6acd0021cac10d5",
    teleporterMessenger: "0x253b2784c75e510dD0fF1da844684a1aC0aa5fcf",
  },
};

export const AVALANCHE_MAINNET: ChainConfig = {
  name: "Avalanche C-Chain",
  chainId: 43114,
  rpcUrl: "https://api.avax.network/ext/bc/C/rpc",
  explorerUrl: "https://snowtrace.io",
  bridgeProtocol: "Teleporter",
  ecosystem: "avalanche",
  nativeToken: "AVAX",
  blockTimeMs: 2000,
  contracts: { ...ZERO },
  meta: {},
};

// ══════════════════════════════════════════════════════════════════════
//  POLKADOT ECOSYSTEM
// ══════════════════════════════════════════════════════════════════════

export const MOONBASE_ALPHA: ChainConfig = {
  name: "Moonbase Alpha",
  chainId: 1287,
  rpcUrl: "https://rpc.api.moonbase.moonbeam.network",
  explorerUrl: "https://moonbase.moonscan.io",
  bridgeProtocol: "XCM",
  ecosystem: "polkadot",
  nativeToken: "DEV",
  blockTimeMs: 12000,
  contracts: { ...ZERO },
  meta: {
    paraId: 1000,
    xcmTransactorV2: "0x000000000000000000000000000000000000080D",
  },
};

export const MOONBEAM: ChainConfig = {
  name: "Moonbeam",
  chainId: 1284,
  rpcUrl: "https://rpc.api.moonbeam.network",
  explorerUrl: "https://moonbeam.moonscan.io",
  bridgeProtocol: "XCM",
  ecosystem: "polkadot",
  nativeToken: "GLMR",
  blockTimeMs: 12000,
  contracts: { ...ZERO },
  meta: { paraId: 2004 },
};

export const ASTAR_SHIBUYA: ChainConfig = {
  name: "Astar Shibuya",
  chainId: 81,
  rpcUrl: "https://evm.shibuya.astar.network",
  explorerUrl: "https://shibuya.subscan.io",
  bridgeProtocol: "XCM",
  ecosystem: "polkadot",
  nativeToken: "SBY",
  blockTimeMs: 12000,
  contracts: { ...ZERO },
  meta: { paraId: 2000 },
};

export const ASTAR: ChainConfig = {
  name: "Astar",
  chainId: 592,
  rpcUrl: "https://evm.astar.network",
  explorerUrl: "https://astar.subscan.io",
  bridgeProtocol: "XCM",
  ecosystem: "polkadot",
  nativeToken: "ASTR",
  blockTimeMs: 12000,
  contracts: { ...ZERO },
  meta: { paraId: 2006 },
};

// ══════════════════════════════════════════════════════════════════════
//  COSMOS ECOSYSTEM
// ══════════════════════════════════════════════════════════════════════

export const EVMOS_TESTNET: ChainConfig = {
  name: "Evmos Testnet",
  chainId: 9000,
  rpcUrl: "https://eth.bd.evmos.dev:8545",
  explorerUrl: "https://testnet.escan.live",
  bridgeProtocol: "IBC",
  ecosystem: "cosmos",
  nativeToken: "tEVMOS",
  blockTimeMs: 6000,
  contracts: { ...ZERO },
  meta: {
    ibcPrecompile: "0x0000000000000000000000000000000000000802",
    cosmosChainId: "evmos_9000-4",
  },
};

export const EVMOS: ChainConfig = {
  name: "Evmos",
  chainId: 9001,
  rpcUrl: "https://eth.bd.evmos.org:8545",
  explorerUrl: "https://escan.live",
  bridgeProtocol: "IBC",
  ecosystem: "cosmos",
  nativeToken: "EVMOS",
  blockTimeMs: 6000,
  contracts: { ...ZERO },
  meta: { cosmosChainId: "evmos_9001-2" },
};

// ══════════════════════════════════════════════════════════════════════
//  NEAR ECOSYSTEM
// ══════════════════════════════════════════════════════════════════════

export const AURORA_TESTNET: ChainConfig = {
  name: "Aurora Testnet",
  chainId: 1313161555,
  rpcUrl: "https://testnet.aurora.dev",
  explorerUrl: "https://testnet.aurorascan.dev",
  bridgeProtocol: "RainbowBridge",
  ecosystem: "near",
  nativeToken: "ETH",
  blockTimeMs: 1000,
  contracts: { ...ZERO },
  meta: {
    nearAccount: "aurora",
    crossContractPrecompile: "0x516Cded1D16af10CAd47D6D49128E2eB7d27b372",
  },
};

export const AURORA: ChainConfig = {
  name: "Aurora",
  chainId: 1313161554,
  rpcUrl: "https://mainnet.aurora.dev",
  explorerUrl: "https://aurorascan.dev",
  bridgeProtocol: "RainbowBridge",
  ecosystem: "near",
  nativeToken: "ETH",
  blockTimeMs: 1000,
  contracts: { ...ZERO },
  meta: {},
};

// ── Chain Registry ───────────────────────────────────────────────────

export const ALL_CHAINS: Record<string, ChainConfig> = {
  // Avalanche
  avalanche_fuji: AVALANCHE_FUJI,
  avalanche: AVALANCHE_MAINNET,
  // Polkadot
  moonbase_alpha: MOONBASE_ALPHA,
  moonbeam: MOONBEAM,
  astar_shibuya: ASTAR_SHIBUYA,
  astar: ASTAR,
  // Cosmos
  evmos_testnet: EVMOS_TESTNET,
  evmos: EVMOS,
  // Near
  aurora_testnet: AURORA_TESTNET,
  aurora: AURORA,
};

export function getChainByChainId(chainId: number): ChainConfig | undefined {
  return Object.values(ALL_CHAINS).find((c) => c.chainId === chainId);
}

export function getChainsByEcosystem(
  ecosystem: ChainConfig["ecosystem"],
): ChainConfig[] {
  return Object.values(ALL_CHAINS).filter((c) => c.ecosystem === ecosystem);
}

export function getTestnetChains(): ChainConfig[] {
  return Object.values(ALL_CHAINS).filter(
    (c) =>
      c.name.toLowerCase().includes("testnet") ||
      c.name.toLowerCase().includes("fuji") ||
      c.name.toLowerCase().includes("alpha") ||
      c.name.toLowerCase().includes("shibuya"),
  );
}
