import tables
import waku/waku_lightpush/rpc

type
  PeerId = string
  ReputationIndicator = bool
  ResponseQuality = bool

  ReputationManager* = ref object
    peerReputation*: Table[PeerId, ReputationIndicator]

  DummyResponse* = object
    peerId*: PeerId
    responseQuality*: ResponseQuality

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
    # Default to true if peer not found
    result = true

proc evaluateResponse*(response: DummyResponse): ResponseQuality =
  return response.responseQuality

# Evaluate a PushResponse by checking the isSuccess field.
proc evaluateResponse*(response: PushResponse): bool =
  return response.isSuccess
