import chronos
import ../../waku/node/v2/standard_setup
export standard_setup

proc generateNodes*(num: Natural, gossip: bool = false): seq[Switch] =
  for i in 0..<num:
    result.add(newStandardSwitch(gossip = gossip))

proc subscribeNodes*(nodes: seq[Switch]) {.async.} =
  var dials: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        dials.add(dialer.connect(node.peerInfo))
        # TODO: Hmm, does this make sense?
        await allFutures(dials)
