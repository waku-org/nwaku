{.used.}

import results, chronos, libp2p/crypto/crypto

import
  logos_delivery/kernel/[node/peer_manager/peer_manager],
  logos_delivery/kernel/core/[topics/sharding, message],
  logos_delivery/kernel/core/topics/sharding,
  logos_delivery/kernel/protocols/lightpush/[protocol, common],
  logos_delivery/kernel/protocols/lightpush/[client, common],
  logos_delivery/kernel/common/rate_limit/setting,
  ../testlib/[wakucore]

proc newTestWakuLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
): Future[WakuLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    wakuAutoSharding = Sharding.init(1, 8)
    proto = WakuLightPush.new(
      peerManager,
      crypto.newRng(),
      handler,
      Opt.some(wakuAutoSharding),
      rateLimitSetting,
      maxMessageSize,
    )

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLightpushClient*(switch: Switch): WakuLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLightPushClient.new(peerManager, crypto.newRng())
