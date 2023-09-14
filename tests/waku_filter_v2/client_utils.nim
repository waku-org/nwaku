import
  std/[options,tables],
  testutils/unittests,
  chronos,
  chronicles

import
  ../../../waku/node/peer_manager,
  ../../../waku/waku_filter_v2,
  ../../../waku/waku_filter_v2/client,
  ../../../waku/waku_core,
  ../testlib/common,
  ../testlib/wakucore

proc newTestWakuFilter*(switch: Switch): Future[WakuFilter] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilter.new(peerManager)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuFilterClient*(switch: Switch, messagePushHandler: MessagePushHandler): Future[WakuFilterClient] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuFilterClient.new(rng, messagePushHandler, peerManager)

  await proto.start()
  switch.mount(proto)

  return proto
