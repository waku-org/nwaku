import
  std/[
    options,
    tables,
    sets
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
  var contentTopics: seq[ContentTopic] = @[]
  let peersCreitera = wakuFilter.subscriptions.getPeerSubscriptions(peerId)

  for filterCriterion in peersCreitera:
    contentTopics.add(filterCriterion.contentTopic)

  return contentTopics

proc cmpSeqNoOrder*[T](seq1, seq2: seq[T]): bool {.noSideEffect.} =
  if seq1.len() != seq2.len():
    return false

  for item in seq1:
    if item notin seq2:
      return false

  return true
