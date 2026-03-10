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
  m.save();
}

export function handleTransfer(event: TransferEvent): void {
  let id =
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString();

  let entity = new Transfer(id);
  entity.nullifier0 = event.params.nullifier0;
  entity.nullifier1 = event.params.nullifier1;
  entity.outputCommitment0 = event.params.outputCommitment0;
  entity.outputCommitment1 = event.params.outputCommitment1;
  entity.newRoot = event.params.newRoot;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.timestamp = event.block.timestamp;
  entity.save();

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
  entity.nullifier0 = event.params.nullifier0;
  entity.nullifier1 = event.params.nullifier1;
  entity.recipient = event.params.recipient;
  entity.exitValue = event.params.exitValue;
  entity.newRoot = event.params.newRoot;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.timestamp = event.block.timestamp;
  entity.save();

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
    event.params.exitValue.toBigDecimal(),
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
