import std/json
import
  chronicles,
  chronos,
  results,
  eth/p2p/discoveryv5/enr,
  strutils,
  libp2p/peerid,
  metrics,
  ffi
import
  ../../waku/factory/waku, ../../waku/node/waku_node, ../../waku/node/health_monitor

proc getMultiaddresses(node: WakuNode): seq[string] =
  return node.info().listenAddresses

proc getMetrics(): string =
  {.gcsafe.}:
    return defaultRegistry.toText() ## defaultRegistry is {.global.} in metrics module

registerReqFFI(GetWakuVersionReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok(WakuNodeVersionString)

registerReqFFI(GetListenAddressesReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    ## returns a comma-separated string of the listen addresses
    return ok(waku.node.getMultiaddresses().join(","))

registerReqFFI(GetMyEnrReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok(waku.node.enr.toURI())

registerReqFFI(GetMyPeerIdReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok($waku.node.peerId())

registerReqFFI(GetMetricsReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok(getMetrics())

registerReqFFI(IsOnlineReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    return ok($waku.healthMonitor.onlineMonitor.amIOnline())
