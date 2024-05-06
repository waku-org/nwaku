{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import ../../../waku/[node/peer_manager, waku_core, waku_sync], ../testlib/wakucore

proc newTestWakuSync*(
    switch: Switch, handler: SyncCallback
): Future[WakuSync] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuSync.new(
      peerManager = peerManager, relayJitter = 0.seconds, syncCB = some(handler)
    )
  assert proto != nil

  proto.start()
  switch.mount(proto)

  return proto
