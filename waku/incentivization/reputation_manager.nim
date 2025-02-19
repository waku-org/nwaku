import tables
import waku/waku_lightpush/rpc

type
  PeerId = string

  ReputationIndicator* = enum
    BadRep
    GoodRep
    UnknownRep

  ResponseQuality* = enum
    BadResponse
    GoodResponse

  ReputationManager* = ref object
    reputationOf*: Table[PeerId, ReputationIndicator]

proc init*(T: type ReputationManager): ReputationManager =
  return ReputationManager(reputationOf: initTable[PeerId, ReputationIndicator]())

proc setReputation*(
    manager: var ReputationManager, peer: PeerId, repIndicator: ReputationIndicator
) =
  manager.reputationOf[peer] = repIndicator

proc getReputation*(manager: ReputationManager, peer: PeerId): ReputationIndicator =
  if peer in manager.reputationOf:
    result = manager.reputationOf[peer]
  else:
    result = UnknownRep

# Evaluate the quality of a PushResponse by checking its isSuccess field
proc evaluateResponse*(response: PushResponse): ResponseQuality =
  if response.isSuccess:
    return GoodResponse
  else:
    return BadResponse

# Update reputation of the peer based on the quality of a response
proc updateReputationFromResponse*(
    manager: var ReputationManager, peer: PeerId, response: PushResponse
) =
  let respQuality = evaluateResponse(response)
  case respQuality
  of BadResponse:
    manager.setReputation(peer, BadRep)
  of GoodResponse:
    manager.setReputation(peer, GoodRep)
