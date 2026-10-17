{.push raises: [].}

import std/sets
import chronos, libp2p/peerid
import logos_delivery/kernel/[node/peer_manager/peers], ./health_monitor/topic_health

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
  pending*: seq[Future[void]]
  pendingPeers*: HashSet[PeerId]
  currentHealth*: TopicHealth

{.pop.}
