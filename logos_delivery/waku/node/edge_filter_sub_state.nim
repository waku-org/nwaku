{.push raises: [].}

import std/sets
import chronos, libp2p/peerid
import ../waku_core, ./health_monitor/topic_health

type EdgeFilterSubState* = object
  peers*: seq[RemotePeerInfo]
  pending*: seq[Future[void]]
  pendingPeers*: HashSet[PeerId]
  currentHealth*: TopicHealth
  slotPeerTried*: bool
    ## True after the edge tried the configured filter peer for this shard. Each
    ## tick of `edgeFilterConnectionLoop` that finds the shard with fewer than
    ## `HealthyThreshold` peers clears it.

{.pop.}
