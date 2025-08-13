import
  std/[options, sequtils, random],
  results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../common/nimchronos,
  ../node/peer_manager,
  ../waku_core,
  ../discovery/waku_discv5,
  ./rpc,
  ./rpc_codec,
  ../common/rate_limit/request_limiter,
  ./common

from ../waku_core/codecs import WakuPeerExchangeCodec
export WakuPeerExchangeCodec

declarePublicGauge waku_px_peers_received_unknown,
  "number of previously unknown ENRs received via peer exchange"
declarePublicGauge waku_px_peers_cached, "number of peer exchange peer ENRs cached"
declarePublicCounter waku_px_errors, "number of peer exchange errors", ["type"]
declarePublicCounter waku_px_peers_sent,
  "number of ENRs sent to peer exchange requesters"

logScope:
  topics = "waku peer_exchange"

type WakuPeerExchange* = ref object of LPProtocol
  peerManager*: PeerManager
  enrCache*: seq[enr.Record]
  cluster*: Option[uint16]
    # todo: next step: ring buffer; future: implement cache satisfying https://rfc.vac.dev/spec/34/
  requestRateLimiter*: RequestRateLimiter
  pxLoopHandle*: Future[void]

proc respond(
    wpx: WakuPeerExchange, enrs: seq[enr.Record], conn: Connection
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeResponse(enrs.mapIt(PeerExchangePeerInfo(enr: it.raw)))

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    error "exception when trying to send a respond", error = getCurrentExceptionMsg()
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.DIAL_FAILURE,
        status_desc: some("exception dialing peer: " & exc.msg),
      )
    )

  return ok()

proc respondError(
    wpx: WakuPeerExchange,
    status_code: PeerExchangeResponseStatusCode,
    status_desc: Option[string],
    conn: Connection,
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeErrorResponse(status_code, status_desc)

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    error "exception when trying to send a respond", error = getCurrentExceptionMsg()
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      (
        status_code: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        status_desc: some("exception dialing peer: " & exc.msg),
      )
    )

  return ok()

proc getEnrsFromCache(
    wpx: WakuPeerExchange, numPeers: uint64
): seq[enr.Record] {.gcsafe.} =
  if wpx.enrCache.len() == 0:
    debug "peer exchange ENR cache is empty"
    return @[]

  # copy and shuffle
  randomize()
  var shuffledCache = wpx.enrCache
  shuffledCache.shuffle()

  # return numPeers or less if cache is smaller
  return shuffledCache[0 ..< min(shuffledCache.len.int, numPeers.int)]

proc poolFilter*(cluster: Option[uint16], peer: RemotePeerInfo): bool =
  if peer.origin != Discv5:
    debug "peer not from discv5", peer = $peer, origin = $peer.origin
    return false

  if peer.enr.isNone():
    debug "peer has no ENR", peer = $peer
    return false

  if cluster.isSome() and peer.enr.get().isClusterMismatched(cluster.get()):
    debug "peer has mismatching cluster", peer = $peer
    return false

  return true

proc populateEnrCache(wpx: WakuPeerExchange) =
  # share only peers that i) are reachable ii) come from discv5 iii) share cluster
  let withEnr = wpx.peerManager.switch.peerStore.getReachablePeers().filterIt(
      poolFilter(wpx.cluster, it)
    )

  # either what we have or max cache size
  var newEnrCache = newSeq[enr.Record](0)
  for i in 0 ..< min(withEnr.len, MaxPeersCacheSize):
    newEnrCache.add(withEnr[i].enr.get())

  # swap cache for new
  wpx.enrCache = newEnrCache
  trace "ENR cache populated"

proc updatePxEnrCache(wpx: WakuPeerExchange) {.async.} =
  # try more aggressively to fill the cache at startup
  var attempts = 50
  while wpx.enrCache.len < MaxPeersCacheSize and attempts > 0:
    attempts -= 1
    wpx.populateEnrCache()
    await sleepAsync(1.seconds)

  heartbeat "Updating px enr cache", CacheRefreshInterval:
    wpx.populateEnrCache()

proc initProtocolHandler(wpx: WakuPeerExchange) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]
    wpx.requestRateLimiter.checkUsageLimit(WakuPeerExchangeCodec, conn):
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize.int)
      except CatchableError as exc:
        error "exception when handling px request", error = getCurrentExceptionMsg()
        waku_px_errors.inc(labelValues = [exc.msg])

        (
          try:
            await wpx.respondError(
              PeerExchangeResponseStatusCode.BAD_REQUEST, some(exc.msg), conn
            )
          except CatchableError:
            error "could not send error response", error = getCurrentExceptionMsg()
            return
        ).isOkOr:
          error "Failed to respond with BAD_REQUEST:", error = $error
        return

      let decBuf = PeerExchangeRpc.decode(buffer)
      if decBuf.isErr():
        waku_px_errors.inc(labelValues = [decodeRpcFailure])
        error "Failed to decode PeerExchange request", error = $decBuf.error

        (
          try:
            await wpx.respondError(
              PeerExchangeResponseStatusCode.BAD_REQUEST, some($decBuf.error), conn
            )
          except CatchableError:
            error "could not send error response decode",
              error = getCurrentExceptionMsg()
            return
        ).isOkOr:
          error "Failed to respond with BAD_REQUEST:", error = $error
        return

      let enrs = wpx.getEnrsFromCache(decBuf.get().request.numPeers)
      debug "peer exchange request received", enrs = $enrs

      try:
        (await wpx.respond(enrs, conn)).isErrOr:
          waku_px_peers_sent.inc(enrs.len().int64())
      except CatchableError:
        error "could not send response", error = getCurrentExceptionMsg()
    do:
      defer:
        # close, no data is expected
        await conn.closeWithEof()

      try:
        (
          await wpx.respondError(
            PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS, none(string), conn
          )
        ).isOkOr:
          error "Failed to respond with TOO_MANY_REQUESTS:", error = $error
      except CatchableError:
        error "could not send error response", error = getCurrentExceptionMsg()
        return

  wpx.handler = handler
  wpx.codec = WakuPeerExchangeCodec

proc new*(
    T: type WakuPeerExchange,
    peerManager: PeerManager,
    cluster: Option[uint16] = none(uint16),
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wpx = WakuPeerExchange(
    peerManager: peerManager,
    cluster: cluster,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
  )
  wpx.initProtocolHandler()
  setServiceLimitMetric(WakuPeerExchangeCodec, rateLimitSetting)
  asyncSpawn wpx.updatePxEnrCache()
  return wpx
