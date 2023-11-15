when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets,tables],
  chronicles,
  libp2p/peerid
import
  ../waku_core

logScope:
  topics = "waku filter subscriptions"

const
  MaxTotalSubscriptions* = 1000 # TODO make configurable
  MaxCriteriaPerSubscription* = 1000

type
  FilterCriterion* = (PubsubTopic, ContentTopic) # a single filter criterion is fully defined by a pubsub topic and content topic
  FilterCriteria* = HashSet[FilterCriterion] # a sequence of filter criteria
  FilterSubscriptions* = Table[PeerID, FilterCriteria] # a mapping of peer ids to a sequence of filter criteria

proc findSubscribedPeers*(subscriptions: FilterSubscriptions, pubsubTopic: PubsubTopic, contentTopic: ContentTopic): seq[PeerID] =
  ## Find all peers subscribed to a given topic and content topic
  let filterCriterion = (pubsubTopic, contentTopic)

  var subscribedPeers: seq[PeerID]

  # TODO: for large maps, this can be optimized using a reverse index
  for (peerId, criteria) in subscriptions.pairs():
    if filterCriterion in criteria:
      subscribedPeers.add(peerId)

  subscribedPeers

proc removePeer*(subscriptions: var FilterSubscriptions, peerId: PeerID) =
  ## Remove all subscriptions for a given peer
  subscriptions.del(peerId)

proc removePeers*(subscriptions: var FilterSubscriptions, peerIds: seq[PeerID]) =
  ## Remove all subscriptions for a given list of peers
  for peerId in peerIds:
    subscriptions.removePeer(peerId)

proc containsAny*(criteria: FilterCriteria, otherCriteria: FilterCriteria): bool =
  ## Check if a given pubsub topic is contained in a set of filter criteria
  ## TODO: Better way to achieve this?
  for criterion in otherCriteria:
    if criterion in criteria:
      return true
  false
