{.used.}

import results, chronos, chronicles, libp2p/crypto/crypto

logScope:
  topics = "test waku_lightpush_legacy"

import
  logos_delivery/kernel/[
    peer_manager/peer_manager,
    base/message,
    protocols/lightpush_legacy/protocol,
    protocols/lightpush_legacy/common,
    protocols/lightpush_legacy/client,
    base/rate_limit/setting,
  ],
  ../testlib/wakucore
proc newTestWakuLegacyLightpushNode*(
    switch: Switch,
    handler: PushMessageHandler,
    rateLimitSetting: Opt[RateLimitSetting] = Opt.none(RateLimitSetting),
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
): Future[WakuLegacyLightPush] {.async.} =
  let
    peerManager = PeerManager.new(switch)
    proto = WakuLegacyLightPush.new(
      peerManager, crypto.newRng(), handler, rateLimitSetting, maxMessageSize
    )

  await proto.start()
  switch.mount(proto)

  return proto

proc newTestWakuLegacyLightpushClient*(switch: Switch): WakuLegacyLightPushClient =
  let peerManager = PeerManager.new(switch)
  WakuLegacyLightPushClient.new(peerManager, crypto.newRng())
