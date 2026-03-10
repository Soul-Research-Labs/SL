import { BigInt } from "@graphprotocol/graph-ts";
import {
  EpochFinalized as EpochFinalizedEvent,
  RemoteRootReceived as RemoteRootReceivedEvent,
} from "../generated/EpochManager/EpochManager";
import { Epoch, CrossChainSync } from "../generated/schema";

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

export function handleRemoteRootReceived(event: RemoteRootReceivedEvent): void {
  let id =
    event.params.sourceChainId.toString() +
    "-" +
    event.params.epochId.toString();

  let entity = new CrossChainSync(id);
  entity.epoch = event.params.epochId.toString();
  entity.sourceChainId = event.params.sourceChainId;
  entity.root = event.params.root;
  entity.receivedAt = event.block.timestamp;
  entity.blockNumber = event.block.number;
  entity.transactionHash = event.transaction.hash;
  entity.save();
}
