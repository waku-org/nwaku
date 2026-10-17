{.used.}

import chronos

import
  logos_delivery/kernel/
    [node/peer_manager/peer_manager, protocols/store/protocol, protocols/store/client],
  ../testlib/[common, wakucore]

proc newTestWakuStore*(
    switch: Switch, handler: StoreQueryRequestHandler
): Future[WakuStore] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuStore.new(peerManager, common.rng(), handler)

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuStoreClient*(switch: Switch): WakuStoreClient {.gcsafe.} =
  let peerManager = PeerManager.new(switch)
  WakuStoreClient.new(peerManager, common.rng())
