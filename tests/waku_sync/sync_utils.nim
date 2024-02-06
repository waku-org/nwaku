{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import
  ../../../waku/[node/peer_manager, waku_core, waku_sync], ../testlib/[common, wakucore]

proc newTestWakuSync*(
    switch: Switch, handler: WakuSyncCallback
): Future[WakuSync] {.async.} =
  const DefaultFrameSize = 153600
  let
    peerManager = PeerManager.new(switch)
    proto = WakuSync.new(peerManager, DefaultFrameSize, 0.seconds, some(handler))
  assert proto != nil

  proto.start()
  switch.mount(proto)

  return proto
