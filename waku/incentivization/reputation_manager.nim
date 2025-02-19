import tables
import waku/waku_lightpush/rpc

type
  PeerId = string
  ReputationIndicator* = enum
    BadRep
    GoodRep

  ResponseQuality = bool

  ReputationManager* = ref object
    peerReputation*: Table[PeerId, ReputationIndicator]

proc init*(T: type ReputationManager): ReputationManager =
  return ReputationManager(peerReputation: initTable[PeerId, ReputationIndicator]())

proc setReputation*(
    manager: var ReputationManager,
    peer: PeerId,
    reputationIndicator: ReputationIndicator,
) =
  manager.peerReputation[peer] = reputationIndicator

proc getReputation*(manager: ReputationManager, peer: PeerId): ReputationIndicator =
  if peer in manager.peerReputation:
    result = manager.peerReputation[peer]
  else:
    # Default to GoodRep if peer not found
    result = GoodRep

# Evaluate a PushResponse by checking the isSuccess field.
proc evaluateResponse*(response: PushResponse): ReputationIndicator =
  if response.isSuccess:
    return GoodRep
  else:
    return BadRep
