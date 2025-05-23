import tables, std/options
import ../waku_lightpush/[rpc, common]
import libp2p/peerid

type
  ResponseQuality* = enum
    BadResponse
    GoodResponse

  # Encode reputation indicator as Option[bool]:
  #   some(true)  => GoodRep
  #   some(false) => BadRep
  #   none(bool)  => unknown / not set
  ReputationManager* = ref object
    reputationOf*: Table[PeerId, Option[bool]]

proc init*(T: type ReputationManager): ReputationManager =
  return ReputationManager(reputationOf: initTable[PeerId, Option[bool]]())

proc setReputation*(
    manager: var ReputationManager, peer: PeerId, repValue: Option[bool]
) =
  manager.reputationOf[peer] = repValue

proc getReputation*(manager: ReputationManager, peer: PeerId): Option[bool] =
  if peer in manager.reputationOf:
    result = manager.reputationOf[peer]
  else:
    result = none(bool)

### Lightpush-specific functionality ###

# Evaluate the quality of a LightPushResponse by checking its status code
proc evaluateResponse*(response: LightPushResponse): ResponseQuality =
  if response.statusCode == LightpushStatusCode.SUCCESS.uint32:
    return GoodResponse
  else:
    return BadResponse

# Update reputation of the peer based on LightPushResponse quality
proc updateReputationFromResponse*(
    manager: var ReputationManager, peer: PeerId, response: LightPushResponse
) =
  let respQuality = evaluateResponse(response)
  case respQuality
  of BadResponse:
    manager.setReputation(peer, some(false)) # false => BadRep
  of GoodResponse:
    manager.setReputation(peer, some(true)) # true  => GoodRep
