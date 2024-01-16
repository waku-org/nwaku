import
  std/[
    options,
    tables,
    sets,
    sequtils,
    algorithm
  ],
  chronos,
  chronicles,
  os

import
  ../../../waku/[
    node/peer_manager,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_filter_v2/subscriptions,
    waku_core
  ],
  ../testlib/[
    common,
    wakucore
  ]


proc newTestWakuFilter*(switch: Switch,
                        subscriptionTimeout: Duration = DefaultSubscriptionTimeToLiveSec,
                        maxFilterPeers: uint32 = MaxFilterPeers,
                        maxFilterCriteriaPerPeer: uint32 = MaxFilterCriteriaPerPeer):
                    Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager, subscriptionTimeout, maxFilterPeers, maxFilterCriteriaPerPeer)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuFilterClient*(switch: Switch): Future[WakuFilterClient] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilterClient.new(peerManager, rng)

  await proto.start()
  switch.mount(proto)

  return proto

proc getSubscribedContentTopics*(wakuFilter: WakuFilter, peerId: PeerId): seq[ContentTopic] =
  var contentTopics: seq[ContentTopic] = @[]
  let peersCriteria = wakuFilter.subscriptions.getPeerSubscriptions(peerId)

  for filterCriterion in peersCriteria:
    contentTopics.add(filterCriterion.contentTopic)

  return contentTopics

proc unorderedCompare*[T](a, b: seq[T]): bool =
  if a == b:
    return true

  var aSorted = a
  var bSorted = b
  aSorted.sort()
  bSorted.sort()

  return aSorted == bSorted
