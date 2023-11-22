import
  std/[
    options, 
    tables,
    sets
  ],
  chronos,
  chronicles

import
  ../../../waku/[
    node/peer_manager,
    waku_filter_v2,
    waku_filter_v2/client,
    waku_core
  ],
  ../testlib/[
    common,
    wakucore
  ]


proc newTestWakuFilter*(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

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
  var contentTopics: seq[ContentTopic]
  for filterCriterion in wakuFilter.subscriptions[peerId]:
    contentTopics.add(filterCriterion[1])

  return contentTopics
