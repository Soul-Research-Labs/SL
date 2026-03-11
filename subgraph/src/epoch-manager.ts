import { BigInt } from "@graphprotocol/graph-ts";
import {
  EpochStarted as EpochStartedEvent,
  EpochFinalized as EpochFinalizedEvent,
  RemoteEpochRootReceived as RemoteEpochRootReceivedEvent,
} from "../generated/EpochManager/EpochManager";
import {
  Epoch,
  EpochStartedEvent as EpochStartedEntity,
  CrossChainSync,
} from "../generated/schema";

export function handleEpochStarted(event: EpochStartedEvent): void {
  let id = "started-" + event.params.epochId.toString();

  let entity = new EpochStartedEntity(id);
  entity.epochId = event.params.epochId;
  entity.startTime = event.params.startTime;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleEpochFinalized(event: EpochFinalizedEvent): void {
  let id = event.params.epochId.toString();

  let entity = new Epoch(id);
  entity.epochId = event.params.epochId;
  entity.nullifierRoot = event.params.nullifierRoot;
  entity.nullifierCount = event.params.nullifierCount;
  entity.finalizedAt = event.block.timestamp;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}

export function handleRemoteEpochRootReceived(
  event: RemoteEpochRootReceivedEvent,
): void {
  let id =
    event.params.sourceChainId.toString() +
    "-" +
    event.params.epochId.toString();

  let entity = new CrossChainSync(id);
  entity.epoch = event.params.epochId.toString();
  entity.sourceChainId = event.params.sourceChainId;
  entity.root = event.params.nullifierRoot;
  entity.receivedAt = event.block.timestamp;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}
