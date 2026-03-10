/**
 * Subgraph query client for the Soul Privacy Stack.
 * Queries The Graph (or any compatible GraphQL endpoint) for indexed events.
 */

// ── Types ──────────────────────────────────────────────

export interface SubgraphConfig {
  /** The Graph endpoint URL */
  endpoint: string;
  /** Optional fetch implementation (defaults to global fetch) */
  fetchFn?: typeof fetch;
}

export interface DepositEntity {
  id: string;
  commitment: string;
  leafIndex: string;
  amount: string;
  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface TransferEntity {
  id: string;
  nullifier0: string;
  nullifier1: string;
  outputCommitment0: string;
  outputCommitment1: string;
  newRoot: string;
  blockNumber: string;
  transactionHash: string;
  timestamp: string;
}

export interface WithdrawalEntity {
  id: string;
  nullifier0: string;
  nullifier1: string;
  recipient: string;
  exitValue: string;
  newRoot: string;
  blockNumber: string;
  transactionHash: string;
  timestamp: string;
}

export interface EpochEntity {
  id: string;
  epochId: string;
  nullifierRoot: string;
  nullifierCount: string;
  finalizedAt: string;
  blockNumber: string;
  transactionHash: string;
}

export interface PoolMetricsEntity {
  id: string;
  totalDeposits: string;
  totalWithdrawals: string;
  totalTransfers: string;
  totalDepositedValue: string;
  totalWithdrawnValue: string;
  uniqueDepositors: string;
  paused: boolean;
}

export interface TimelockTransactionEntity {
  id: string;
  txHash: string;
  target: string;
  value: string;
  data: string;
  eta: string;
  status: string;
  queuedAt: string;
  executedAt: string | null;
  cancelledAt: string | null;
  blockNumber: string;
  transactionHash: string;
}

export interface PaginationOpts {
  first?: number;
  skip?: number;
  orderBy?: string;
  orderDirection?: "asc" | "desc";
}

// ── Client ─────────────────────────────────────────────

export class SubgraphClient {
  private endpoint: string;
  private fetchFn: typeof fetch;

  constructor(config: SubgraphConfig) {
    this.endpoint = config.endpoint;
    this.fetchFn = config.fetchFn ?? globalThis.fetch;
  }

  // ── Input sanitization ─────────────────────────────

  /** Sanitize a hex value for safe GraphQL interpolation. */
  private static sanitizeHex(value: string): string {
    const cleaned = value.toLowerCase().trim();
    if (!/^0x[0-9a-f]+$/.test(cleaned)) {
      throw new Error(`Invalid hex value: ${value}`);
    }
    return cleaned;
  }

  /** Sanitize an address for safe GraphQL interpolation. */
  private static sanitizeAddress(value: string): string {
    const cleaned = value.toLowerCase().trim();
    if (!/^0x[0-9a-f]{40}$/.test(cleaned)) {
      throw new Error(`Invalid address: ${value}`);
    }
    return cleaned;
  }

  // ── Raw query helper ───────────────────────────────

  async query<T = unknown>(
    graphql: string,
    variables?: Record<string, unknown>,
  ): Promise<T> {
    const res = await this.fetchFn(this.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query: graphql, variables }),
    });
    if (!res.ok) {
      throw new Error(`Subgraph request failed: ${res.status}`);
    }
    const json = (await res.json()) as {
      data?: T;
      errors?: { message: string }[];
    };
    if (json.errors?.length) {
      throw new Error(`Subgraph error: ${json.errors[0].message}`);
    }
    return json.data as T;
  }

  // ── Deposits ───────────────────────────────────────

  async getDeposits(opts: PaginationOpts = {}): Promise<DepositEntity[]> {
    const {
      first = 100,
      skip = 0,
      orderBy = "blockNumber",
      orderDirection = "desc",
    } = opts;
    const data = await this.query<{ deposits: DepositEntity[] }>(`{
      deposits(first: ${first}, skip: ${skip}, orderBy: ${orderBy}, orderDirection: ${orderDirection}) {
        id commitment leafIndex amount timestamp blockNumber transactionHash
      }
    }`);
    return data.deposits;
  }

  async getDepositByCommitment(
    commitment: string,
  ): Promise<DepositEntity | null> {
    const safe = SubgraphClient.sanitizeHex(commitment);
    const data = await this.query<{ deposits: DepositEntity[] }>(`{
      deposits(where: { commitment: "${safe}" }, first: 1) {
        id commitment leafIndex amount timestamp blockNumber transactionHash
      }
    }`);
    return data.deposits[0] ?? null;
  }

  // ── Transfers ──────────────────────────────────────

  async getTransfers(opts: PaginationOpts = {}): Promise<TransferEntity[]> {
    const {
      first = 100,
      skip = 0,
      orderBy = "blockNumber",
      orderDirection = "desc",
    } = opts;
    const data = await this.query<{ transfers: TransferEntity[] }>(`{
      transfers(first: ${first}, skip: ${skip}, orderBy: ${orderBy}, orderDirection: ${orderDirection}) {
        id nullifier0 nullifier1 outputCommitment0 outputCommitment1 newRoot blockNumber transactionHash timestamp
      }
    }`);
    return data.transfers;
  }

  async getTransferByNullifier(
    nullifier: string,
  ): Promise<TransferEntity | null> {
    const safe = SubgraphClient.sanitizeHex(nullifier);
    const data = await this.query<{ transfers: TransferEntity[] }>(`{
      transfers(where: { nullifier0: "${safe}" }, first: 1) {
        id nullifier0 nullifier1 outputCommitment0 outputCommitment1 newRoot blockNumber transactionHash timestamp
      }
    }`);
    if (data.transfers.length) return data.transfers[0];
    // Try nullifier1
    const data2 = await this.query<{ transfers: TransferEntity[] }>(`{
      transfers(where: { nullifier1: "${safe}" }, first: 1) {
        id nullifier0 nullifier1 outputCommitment0 outputCommitment1 newRoot blockNumber transactionHash timestamp
      }
    }`);
    return data2.transfers[0] ?? null;
  }

  // ── Withdrawals ────────────────────────────────────

  async getWithdrawals(opts: PaginationOpts = {}): Promise<WithdrawalEntity[]> {
    const {
      first = 100,
      skip = 0,
      orderBy = "blockNumber",
      orderDirection = "desc",
    } = opts;
    const data = await this.query<{ withdrawals: WithdrawalEntity[] }>(`{
      withdrawals(first: ${first}, skip: ${skip}, orderBy: ${orderBy}, orderDirection: ${orderDirection}) {
        id nullifier0 nullifier1 recipient exitValue newRoot blockNumber transactionHash timestamp
      }
    }`);
    return data.withdrawals;
  }

  async getWithdrawalsByRecipient(
    recipient: string,
  ): Promise<WithdrawalEntity[]> {
    const safe = SubgraphClient.sanitizeAddress(recipient);
    const data = await this.query<{ withdrawals: WithdrawalEntity[] }>(`{
      withdrawals(where: { recipient: "${safe}" }, orderBy: blockNumber, orderDirection: desc) {
        id nullifier0 nullifier1 recipient exitValue newRoot blockNumber transactionHash timestamp
      }
    }`);
    return data.withdrawals;
  }

  // ── Epochs ─────────────────────────────────────────

  async getEpochs(opts: PaginationOpts = {}): Promise<EpochEntity[]> {
    const {
      first = 50,
      skip = 0,
      orderBy = "epochId",
      orderDirection = "desc",
    } = opts;
    const data = await this.query<{ epochs: EpochEntity[] }>(`{
      epochs(first: ${first}, skip: ${skip}, orderBy: ${orderBy}, orderDirection: ${orderDirection}) {
        id epochId nullifierRoot nullifierCount finalizedAt blockNumber transactionHash
      }
    }`);
    return data.epochs;
  }

  async getLatestEpoch(): Promise<EpochEntity | null> {
    const data = await this.query<{ epochs: EpochEntity[] }>(`{
      epochs(first: 1, orderBy: epochId, orderDirection: desc) {
        id epochId nullifierRoot nullifierCount finalizedAt blockNumber transactionHash
      }
    }`);
    return data.epochs[0] ?? null;
  }

  // ── Pool Metrics ───────────────────────────────────

  async getPoolMetrics(): Promise<PoolMetricsEntity | null> {
    const data = await this.query<{ poolMetrics: PoolMetricsEntity | null }>(`{
      poolMetrics(id: "metrics") {
        id totalDeposits totalWithdrawals totalTransfers totalDepositedValue totalWithdrawnValue uniqueDepositors paused
      }
    }`);
    return data.poolMetrics;
  }

  // ── Timelock Transactions ──────────────────────────

  async getTimelockTransactions(
    status?: "queued" | "executed" | "cancelled",
    opts: PaginationOpts = {},
  ): Promise<TimelockTransactionEntity[]> {
    const {
      first = 50,
      skip = 0,
      orderBy = "queuedAt",
      orderDirection = "desc",
    } = opts;
    const where = status ? `where: { status: "${status}" }, ` : "";
    const data = await this.query<{
      timelockTransactions: TimelockTransactionEntity[];
    }>(`{
      timelockTransactions(${where}first: ${first}, skip: ${skip}, orderBy: ${orderBy}, orderDirection: ${orderDirection}) {
        id txHash target value data eta status queuedAt executedAt cancelledAt blockNumber transactionHash
      }
    }`);
    return data.timelockTransactions;
  }

  // ── Convenience: is nullifier spent? ───────────────

  async isNullifierSpent(nullifier: string): Promise<boolean> {
    const safe = SubgraphClient.sanitizeHex(nullifier);
    const transfer = await this.getTransferByNullifier(safe);
    if (transfer) return true;
    const data = await this.query<{ withdrawals: { id: string }[] }>(`{
      withdrawals(where: { nullifier0: "${safe}" }, first: 1) { id }
    }`);
    if (data.withdrawals.length) return true;
    const data2 = await this.query<{ withdrawals: { id: string }[] }>(`{
      withdrawals(where: { nullifier1: "${safe}" }, first: 1) { id }
    }`);
    return data2.withdrawals.length > 0;
  }
}
