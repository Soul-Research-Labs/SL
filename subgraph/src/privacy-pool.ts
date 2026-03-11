import { BigInt, BigDecimal } from "@graphprotocol/graph-ts";
import {
  Deposit as DepositEvent,
  Transfer as TransferEvent,
  Withdrawal as WithdrawalEvent,
  Paused as PausedEvent,
  Unpaused as UnpausedEvent,
} from "../generated/PrivacyPool/PrivacyPool";
import {
  Deposit,
  Transfer,
  Withdrawal,
  MerkleTreeState,
  PoolMetrics,
  NullifierSpent,
  Depositor,
} from "../generated/schema";

// ── Helpers ────────────────────────────────────────────

function getOrCreateMetrics(): PoolMetrics {
  let m = PoolMetrics.load("metrics");
  if (m == null) {
    m = new PoolMetrics("metrics");
    m.totalDeposits = BigInt.zero();
    m.totalWithdrawals = BigInt.zero();
    m.totalTransfers = BigInt.zero();
    m.totalDepositedValue = BigDecimal.zero();
    m.totalWithdrawnValue = BigDecimal.zero();
    m.uniqueDepositors = BigInt.zero();
    m.paused = false;
  }
  return m;
}

function getOrCreateTreeState(): MerkleTreeState {
  let s = MerkleTreeState.load("current");
  if (s == null) {
    s = new MerkleTreeState("current");
    s.nextLeafIndex = BigInt.zero();
  }
  return s;
}

// ── Handlers ───────────────────────────────────────────

export function handleDeposit(event: DepositEvent): void {
  let id =
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let entity = new Deposit(id);
  entity.commitment = event.params.commitment;
  entity.leafIndex = event.params.leafIndex;
  entity.amount = event.params.amount;
  entity.timestamp = event.params.timestamp;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();

  // Track unique depositors
  let depositorId = event.transaction.from.toHexString();
  let depositor = Depositor.load(depositorId);
  let isNew = depositor == null;
  if (depositor == null) {
    depositor = new Depositor(depositorId);
    depositor.address = event.transaction.from;
    depositor.totalDeposits = BigInt.zero();
    depositor.totalDepositedValue = BigDecimal.zero();
    depositor.firstDepositBlock = event.block.number;
  }
  depositor.totalDeposits = depositor.totalDeposits.plus(BigInt.fromI32(1));
  depositor.totalDepositedValue = depositor.totalDepositedValue.plus(
    event.params.amount.toBigDecimal(),
  );
  depositor.lastDepositBlock = event.block.number;
  depositor.save();

  // Update tree state
  let tree = getOrCreateTreeState();
  tree.nextLeafIndex = event.params.leafIndex.plus(BigInt.fromI32(1));
  tree.lastUpdatedBlock = event.block.number;
  tree.save();

  // Update metrics
  let m = getOrCreateMetrics();
  m.totalDeposits = m.totalDeposits.plus(BigInt.fromI32(1));
  m.totalDepositedValue = m.totalDepositedValue.plus(
    event.params.amount.toBigDecimal(),
  );
  if (isNew) {
    m.uniqueDepositors = m.uniqueDepositors.plus(BigInt.fromI32(1));
  }
  m.save();
}

export function handleTransfer(event: TransferEvent): void {
  let id =
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let entity = new Transfer(id);
  entity.nullifier0 = event.params.nullifier1;
  entity.nullifier1 = event.params.nullifier2;
  entity.outputCommitment0 = event.params.outputCommitment1;
  entity.outputCommitment1 = event.params.outputCommitment2;
  entity.newRoot = event.params.newRoot;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.timestamp = event.block.timestamp;
  entity.save();

  // Track nullifiers spent
  let n0 = new NullifierSpent(event.params.nullifier1.toHexString());
  n0.nullifier = event.params.nullifier1;
  n0.spentIn = id;
  n0.spentAt = event.block.timestamp;
  n0.blockNumber = event.block.number;
  n0.transactionHash = event.transaction.hash;
  n0.save();

  let n1 = new NullifierSpent(event.params.nullifier2.toHexString());
  n1.nullifier = event.params.nullifier2;
  n1.spentIn = id;
  n1.spentAt = event.block.timestamp;
  n1.blockNumber = event.block.number;
  n1.transactionHash = event.transaction.hash;
  n1.save();

  // Update tree state
  let tree = getOrCreateTreeState();
  tree.currentRoot = event.params.newRoot;
  tree.nextLeafIndex = tree.nextLeafIndex.plus(BigInt.fromI32(2));
  tree.lastUpdatedBlock = event.block.number;
  tree.save();

  // Update metrics
  let m = getOrCreateMetrics();
  m.totalTransfers = m.totalTransfers.plus(BigInt.fromI32(1));
  m.save();
}

export function handleWithdrawal(event: WithdrawalEvent): void {
  let id =
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let entity = new Withdrawal(id);
  entity.nullifier0 = event.params.nullifier1;
  entity.nullifier1 = event.params.nullifier2;
  entity.recipient = event.params.recipient;
  entity.exitValue = event.params.amount;
  entity.newRoot = event.params.newRoot;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.timestamp = event.block.timestamp;
  entity.save();

  // Track nullifiers spent
  let wn0 = new NullifierSpent(event.params.nullifier1.toHexString());
  wn0.nullifier = event.params.nullifier1;
  wn0.spentIn = id;
  wn0.spentAt = event.block.timestamp;
  wn0.blockNumber = event.block.number;
  wn0.transactionHash = event.transaction.hash;
  wn0.save();

  let wn1 = new NullifierSpent(event.params.nullifier2.toHexString());
  wn1.nullifier = event.params.nullifier2;
  wn1.spentIn = id;
  wn1.spentAt = event.block.timestamp;
  wn1.blockNumber = event.block.number;
  wn1.transactionHash = event.transaction.hash;
  wn1.save();

  // Update tree state
  let tree = getOrCreateTreeState();
  tree.currentRoot = event.params.newRoot;
  tree.nextLeafIndex = tree.nextLeafIndex.plus(BigInt.fromI32(2));
  tree.lastUpdatedBlock = event.block.number;
  tree.save();

  // Update metrics
  let m = getOrCreateMetrics();
  m.totalWithdrawals = m.totalWithdrawals.plus(BigInt.fromI32(1));
  m.totalWithdrawnValue = m.totalWithdrawnValue.plus(
    event.params.amount.toBigDecimal(),
  );
  m.save();
}

export function handlePaused(event: PausedEvent): void {
  let m = getOrCreateMetrics();
  m.paused = true;
  m.lastPausedBy = event.params.by;
  m.lastPauseReason = event.params.reason;
  m.save();
}

export function handleUnpaused(event: UnpausedEvent): void {
  let m = getOrCreateMetrics();
  m.paused = false;
  m.save();
}
