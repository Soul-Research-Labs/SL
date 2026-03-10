import { BigInt } from "@graphprotocol/graph-ts";
import {
  TransactionQueued as TransactionQueuedEvent,
  TransactionExecuted as TransactionExecutedEvent,
  TransactionCancelled as TransactionCancelledEvent,
} from "../generated/GovernanceTimelock/GovernanceTimelock";
import { TimelockTransaction } from "../generated/schema";

export function handleTransactionQueued(event: TransactionQueuedEvent): void {
  let id = event.params.txHash.toHexString();

  let entity = new TimelockTransaction(id);
  entity.txHash = event.params.txHash;
  entity.target = event.params.target;
  entity.value = event.params.value;
  entity.data = event.params.data;
  entity.eta = event.params.eta;
  entity.status = "queued";
  entity.queuedAt = event.block.timestamp;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleTransactionExecuted(
  event: TransactionExecutedEvent,
): void {
  let id = event.params.txHash.toHexString();

  let entity = TimelockTransaction.load(id);
  if (entity != null) {
    entity.status = "executed";
    entity.executedAt = event.block.timestamp;
    entity.save();
  }
}

export function handleTransactionCancelled(
  event: TransactionCancelledEvent,
): void {
  let id = event.params.txHash.toHexString();

  let entity = TimelockTransaction.load(id);
  if (entity != null) {
    entity.status = "cancelled";
    entity.cancelledAt = event.block.timestamp;
    entity.save();
  }
}
