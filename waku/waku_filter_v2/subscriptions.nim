{.push raises: [].}

import std/[sets, tables], chronicles, chronos, libp2p/peerid, stew/shims/sets
import ../waku_core, ../utils/tableutils, ../common/rate_limit/setting

logScope:
  topics = "waku filter subscriptions"

const
  MaxFilterPeers* = 1000
  MaxFilterCriteriaPerPeer* = 1000
  DefaultSubscriptionTimeToLiveSec* = 5.minutes
  MessageCacheTTL* = 2.minutes

type
  # a single filter criterion is fully defined by a pubsub topic and content topic
  FilterCriterion* = tuple[pubsubTopic: PubsubTopic, contentTopic: ContentTopic]

  FilterCriteria* = HashSet[FilterCriterion] # a sequence of filter criteria

  SubscribedPeers* = HashSet[PeerID] # a sequence of peer ids

  PeerData* = tuple[lastSeen: Moment, criteriaCount: uint]

  FilterSubscriptions* = object
    peersSubscribed*: Table[PeerID, PeerData]
    subscriptions: Table[FilterCriterion, SubscribedPeers]
    subscriptionTimeout: Duration
    maxPeers: uint
    maxCriteriaPerPeer: uint

proc init*(
    T: type FilterSubscriptions,
    subscriptionTimeout: Duration = DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = MaxFilterCriteriaPerPeer,
): FilterSubscriptions =
  ## Create a new filter subscription object
  return FilterSubscriptions(
    peersSubscribed: initTable[PeerID, PeerData](),
    subscriptions: initTable[FilterCriterion, SubscribedPeers](),
    subscriptionTimeout: subscriptionTimeout,
    maxPeers: maxFilterPeers,
    maxCriteriaPerPeer: maxFilterCriteriaPerPeer,
  )

proc isSubscribed*(s: var FilterSubscriptions, peerId: PeerID): bool =
  s.peersSubscribed.withValue(peerId, data):
    return Moment.now() - data.lastSeen <= s.subscriptionTimeout

  return false

proc subscribedPeerCount*(s: FilterSubscriptions): uint =
  return cast[uint](s.peersSubscribed.len)

proc getPeerSubscriptions*(
    s: var FilterSubscriptions, peerId: PeerID
): seq[FilterCriterion] =
  ## Get all pubsub-content topics a peer is subscribed to
  var subscribedContentTopics: seq[FilterCriterion] = @[]
  s.peersSubscribed.withValue(peerId, data):
    if data.criteriaCount == 0:
      return subscribedContentTopics

    for filterCriterion, subscribedPeers in s.subscriptions.mpairs:
      if peerId in subscribedPeers:
        subscribedContentTopics.add(filterCriterion)

  return subscribedContentTopics

proc findSubscribedPeers*(
    s: var FilterSubscriptions, pubsubTopic: PubsubTopic, contentTopic: ContentTopic
): seq[PeerID] =
  let filterCriterion: FilterCriterion = (pubsubTopic, contentTopic)

  var foundPeers: seq[PeerID] = @[]
  # only peers subscribed to criteria and with legit subscription is counted
  s.subscriptions.withValue(filterCriterion, peers):
    for peer in peers[]:
      if s.isSubscribed(peer):
        foundPeers.add(peer)

  return foundPeers

proc removePeer*(s: var FilterSubscriptions, peerId: PeerID) =
  ## Remove all subscriptions for a given peer
  s.peersSubscribed.del(peerId)

proc removePeers*(s: var FilterSubscriptions, peerIds: seq[PeerID]) =
  ## Remove all subscriptions for a given list of peers
  s.peersSubscribed.keepItIf(key notin peerIds)

proc cleanUp*(fs: var FilterSubscriptions) =
  ## Remove all subscriptions for peers that have not been seen for a while
  let now = Moment.now()
  fs.peersSubscribed.keepItIf(now - val.lastSeen <= fs.subscriptionTimeout)

  var filtersToRemove: seq[FilterCriterion] = @[]
  for filterCriterion, subscribedPeers in fs.subscriptions.mpairs:
    subscribedPeers.keepItIf(fs.isSubscribed(it) == true)

  fs.subscriptions.keepItIf(val.len > 0)

proc refreshSubscription*(s: var FilterSubscriptions, peerId: PeerID) =
  s.peersSubscribed.withValue(peerId, data):
    data.lastSeen = Moment.now()

proc addSubscription*(
    s: var FilterSubscriptions, peerId: PeerID, filterCriteria: FilterCriteria
): Result[void, string] =
  ## Add a subscription for a given peer
  var peerData: ptr PeerData

  s.peersSubscribed.withValue(peerId, data):
    if data.criteriaCount + cast[uint](filterCriteria.len) > s.maxCriteriaPerPeer:
      return err("peer has reached maximum number of filter criteria")

    data.lastSeen = Moment.now()
    peerData = data
  do:
    ## not yet subscribed
    if cast[uint](s.peersSubscribed.len) >= s.maxPeers:
      return err("node has reached maximum number of subscriptions")

    let newPeerData: PeerData = (lastSeen: Moment.now(), criteriaCount: 0)
    peerData = addr(s.peersSubscribed.mgetOrPut(peerId, newPeerData))

  for filterCriterion in filterCriteria:
    var peersOfSub = addr(s.subscriptions.mgetOrPut(filterCriterion, SubscribedPeers()))
    if peerId notin peersOfSub[]:
      peersOfSub[].incl(peerId)
      peerData.criteriaCount += 1

  return ok()

proc removeSubscription*(
    s: var FilterSubscriptions, peerId: PeerID, filterCriteria: FilterCriteria
): Result[void, string] =
  ## Remove a subscription for a given peer

  s.peersSubscribed.withValue(peerId, peerData):
    peerData.lastSeen = Moment.now()
    for filterCriterion in filterCriteria:
      s.subscriptions.withValue(filterCriterion, peers):
        if peers[].missingOrexcl(peerId) == false:
          peerData.criteriaCount -= 1

          if peers[].len == 0:
            s.subscriptions.del(filterCriterion)
          if peerData.criteriaCount == 0:
            s.peersSubscribed.del(peerId)
      do:
        ## Maybe let just run through and log it as a warning
        return err("Peer was not subscribed to criterion")

    return ok()
  do:
    return err("Peer has no subscriptions")
