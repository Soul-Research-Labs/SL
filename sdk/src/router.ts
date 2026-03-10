import { type Hex, type Address, type Hash } from "viem";
import { ALL_CHAINS, type ChainConfig } from "./chains";
import { SoulPrivacyClient, MultiChainPrivacyManager } from "./client";

// ── Bridge Topology ────────────────────────────────────

/**
 * Defines which bridge protocol connects each pair of chains.
 * Used by the router to find optimal cross-chain paths.
 */
export interface BridgeEdge {
  source: string;
  destination: string;
  protocol: "AWM" | "Teleporter" | "XCM" | "IBC" | "Rainbow";
  /** Estimated relay time in seconds */
  estimatedLatency: number;
  /** Whether this route is active */
  active: boolean;
}

/** Pre-defined bridge topology for the Soul Privacy Stack */
export const BRIDGE_TOPOLOGY: BridgeEdge[] = [
  // Avalanche internal
  {
    source: "avalanche_fuji",
    destination: "avalanche_fuji_subnet",
    protocol: "AWM",
    estimatedLatency: 5,
    active: true,
  },
  {
    source: "avalanche_fuji_subnet",
    destination: "avalanche_fuji",
    protocol: "AWM",
    estimatedLatency: 5,
    active: true,
  },
  {
    source: "avalanche_fuji",
    destination: "avalanche_fuji_subnet",
    protocol: "Teleporter",
    estimatedLatency: 10,
    active: true,
  },

  // Polkadot parachains (XCM)
  {
    source: "moonbase_alpha",
    destination: "astar_shibuya",
    protocol: "XCM",
    estimatedLatency: 24,
    active: true,
  },
  {
    source: "astar_shibuya",
    destination: "moonbase_alpha",
    protocol: "XCM",
    estimatedLatency: 24,
    active: true,
  },

  // Cosmos (IBC) — Evmos ↔ Osmosis (placeholder for future multi-chain IBC)
  // No self-loop; IBC routes added when a second Cosmos chain is registered

  // Near/Aurora ↔ NEAR mainnet (placeholder; Rainbow is Aurora→Ethereum)
  // No self-loop; add actual cross-chain route when second chain is available

  // Cross-ecosystem via hub (Avalanche ↔ Moonbeam via relayer)
  {
    source: "avalanche_fuji",
    destination: "moonbase_alpha",
    protocol: "AWM",
    estimatedLatency: 60,
    active: true,
  },
  {
    source: "moonbase_alpha",
    destination: "avalanche_fuji",
    protocol: "XCM",
    estimatedLatency: 60,
    active: true,
  },
  {
    source: "avalanche_fuji",
    destination: "evmos_testnet",
    protocol: "AWM",
    estimatedLatency: 60,
    active: true,
  },
  {
    source: "avalanche_fuji",
    destination: "aurora_testnet",
    protocol: "AWM",
    estimatedLatency: 60,
    active: true,
  },
];

// ── Route Planner ──────────────────────────────────────

export interface Route {
  hops: BridgeEdge[];
  totalLatency: number;
  protocols: string[];
}

/**
 * Find all possible routes between two chains.
 * Uses BFS to discover multi-hop paths (max 3 hops).
 */
export function findRoutes(
  source: string,
  destination: string,
  maxHops: number = 3,
  topology: BridgeEdge[] = BRIDGE_TOPOLOGY,
): Route[] {
  if (source === destination) {
    return [{ hops: [], totalLatency: 0, protocols: [] }];
  }

  const activeEdges = topology.filter((e) => e.active);
  const routes: Route[] = [];

  // BFS with path tracking
  interface QueueItem {
    chain: string;
    path: BridgeEdge[];
  }

  const queue: QueueItem[] = [{ chain: source, path: [] }];

  while (queue.length > 0) {
    const current = queue.shift()!;

    if (current.path.length >= maxHops) continue;

    const neighbors = activeEdges.filter((e) => e.source === current.chain);

    for (const edge of neighbors) {
      // Avoid cycles
      if (current.path.some((p) => p.destination === edge.destination)) {
        continue;
      }

      const newPath = [...current.path, edge];

      if (edge.destination === destination) {
        routes.push({
          hops: newPath,
          totalLatency: newPath.reduce((sum, e) => sum + e.estimatedLatency, 0),
          protocols: [...new Set(newPath.map((e) => e.protocol))],
        });
      } else {
        queue.push({ chain: edge.destination, path: newPath });
      }
    }
  }

  // Sort by latency (fastest first)
  return routes.sort((a, b) => a.totalLatency - b.totalLatency);
}

/**
 * Find the optimal (fastest) route between two chains.
 */
export function findOptimalRoute(
  source: string,
  destination: string,
): Route | null {
  const routes = findRoutes(source, destination);
  return routes.length > 0 ? routes[0] : null;
}

// ── Cross-Chain Nullifier Checker ──────────────────────

/**
 * Check if a nullifier has been spent on ANY registered chain.
 * Queries all chains in parallel for fast resolution.
 */
export async function isNullifierSpentAnywhere(
  manager: MultiChainPrivacyManager,
  nullifier: Hex,
): Promise<{ spent: boolean; chain?: string }> {
  const chains = manager.getRegisteredChains();

  const results = await Promise.all(
    chains.map(async (chainKey) => {
      try {
        const client = manager.getClient(chainKey);
        const spent = await client.isNullifierSpent(nullifier);
        return { chainKey, spent };
      } catch {
        return { chainKey, spent: false };
      }
    }),
  );

  const spentOn = results.find((r) => r.spent);
  return spentOn ? { spent: true, chain: spentOn.chainKey } : { spent: false };
}

// ── Cross-Chain Pool Status ────────────────────────────

export interface GlobalPoolStatus {
  chains: {
    chain: string;
    latestRoot: Hex;
    leafCount: bigint;
    reachable: boolean;
  }[];
  totalLeaves: bigint;
  reachableChains: number;
}

/**
 * Get pool status across all registered chains.
 */
export async function getGlobalPoolStatus(
  manager: MultiChainPrivacyManager,
): Promise<GlobalPoolStatus> {
  const chains = manager.getRegisteredChains();

  const statuses = await Promise.all(
    chains.map(async (chainKey) => {
      try {
        const client = manager.getClient(chainKey);
        const status = await client.getPoolStatus();
        return {
          chain: chainKey,
          latestRoot: status.latestRoot,
          leafCount: status.nextLeafIndex,
          reachable: true,
        };
      } catch {
        return {
          chain: chainKey,
          latestRoot: "0x0" as Hex,
          leafCount: 0n,
          reachable: false,
        };
      }
    }),
  );

  return {
    chains: statuses,
    totalLeaves: statuses.reduce((sum, s) => sum + s.leafCount, 0n),
    reachableChains: statuses.filter((s) => s.reachable).length,
  };
}

// ── Shielded Cross-Chain Transfer ──────────────────────

export interface ShieldedCrossChainParams {
  from: string;
  to: string;
  proof: Hex;
  merkleRoot: Hex;
  nullifiers: [Hex, Hex];
  outputCommitments: [Hex, Hex];
}

/**
 * Execute a shielded cross-chain transfer.
 * Automatically finds the optimal route and executes the bridge call.
 */
export async function shieldedCrossChainTransfer(
  manager: MultiChainPrivacyManager,
  params: ShieldedCrossChainParams,
): Promise<{ txHash: Hash; route: Route }> {
  const route = findOptimalRoute(params.from, params.to);
  if (!route) {
    throw new Error(`No route found from ${params.from} to ${params.to}`);
  }

  // For direct routes, use the cross-chain transfer
  const txHash = await manager.crossChainTransfer({
    sourceChain: params.from,
    destinationChain: params.to,
    proof: params.proof,
    merkleRoot: params.merkleRoot,
    nullifiers: params.nullifiers,
    outputCommitments: params.outputCommitments,
  });

  return { txHash, route };
}
