{.used.}

import std/[strutils], stew/shims/net as stewNet, chronos

import ../../../waku/waku_relay, ../../../waku/waku_core, ../testlib/wakucore

proc noopRawHandler*(): WakuRelayHandler =
  var handler: WakuRelayHandler
  handler = proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    discard
  handler

proc newTestWakuRelay*(switch = newTestSwitch()): Future[WakuRelay] {.async.} =
  let proto = WakuRelay.new(switch).tryGet()

  let protocolMatcher = proc(proto: string): bool {.gcsafe.} =
    return proto.startsWith(WakuRelayCodec)

  switch.mount(proto, protocolMatcher)

  return proto
