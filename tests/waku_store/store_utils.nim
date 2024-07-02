{.used.}

import std/options, chronos, chronicles, libp2p/crypto/crypto

import
  waku/[node/peer_manager, waku_core, waku_store, waku_store/client],
  ../testlib/[common, wakucore]

proc newTestWakuStore*(
    switch: Switch, handler: StoreQueryRequestHandler
): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, rng, handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient*(switch: Switch): WakuStoreClient =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, rng)
