import
  std/[options, sequtils, random, sugar],
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
  ../common/rate_limit/request_limiter

declarePublicGauge waku_px_peers_received_total,
  "number of ENRs received via peer exchange"
declarePublicGauge waku_px_peers_received_unknown,
  "number of previously unknown ENRs received via peer exchange"
declarePublicGauge waku_px_peers_sent, "number of ENRs sent to peer exchange requesters"
declarePublicGauge waku_px_peers_cached, "number of peer exchange peer ENRs cached"
declarePublicGauge waku_px_errors, "number of peer exchange errors", ["type"]

logScope:
  topics = "waku peer_exchange"

const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety
  DefaultMaxRpcSize* = 10 * DefaultMaxWakuMessageSize + 64 * 1024
    # TODO what is the expected size of a PX message? As currently specified, it can contain an arbitary number of ENRs...
  MaxPeersCacheSize = 60
  CacheRefreshInterval = 10.minutes

  WakuPeerExchangeCodec* = "/vac/waku/peer-exchange/2.0.0-alpha1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  peerNotFoundFailure = "peer_not_found_failure"
  decodeRpcFailure = "decode_rpc_failure"
  retrievePeersDiscv5Error = "retrieve_peers_discv5_failure"
  pxFailure = "px_failure"

type
  WakuPeerExchangeResult*[T] = Result[T, PeerExchangeResponseStatus]

  WakuPeerExchange* = ref object of LPProtocol
    peerManager*: PeerManager
    enrCache*: seq[enr.Record]
    cluster*: Option[uint16]
      # todo: next step: ring buffer; future: implement cache satisfying https://rfc.vac.dev/spec/34/
    requestRateLimiter*: RequestRateLimiter

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64, conn: Connection
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  let rpc = PeerExchangeRpc.makeRequest(numPeers)

  var buffer: seq[byte]
  var callResult =
    PeerExchangeResponseStatus(status: PeerExchangeResponseStatusCode.SUCCESS)
  try:
    await conn.writeLP(rpc.encode().buffer)
    buffer = await conn.readLp(DefaultMaxRpcSize.int)
  except CatchableError as exc:
    waku_px_errors.inc(labelValues = [exc.msg])
    callResult = PeerExchangeResponseStatus(
      status: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE, desc: some($exc.msg)
    )
  finally:
    # close, no more data is expected
    await conn.closeWithEof()

  if callResult.status != PeerExchangeResponseStatusCode.SUCCESS:
    return err(callResult)

  let decodedBuff = PeerExchangeRpc.decode(buffer)
  if decodedBuff.isErr():
    return err(
      PeerExchangeResponseStatus(
        status: PeerExchangeResponseStatusCode.BAD_RESPONSE,
        desc: some($decodedBuff.error),
      )
    )
  if decodedBuff.get().response.isNone() and decodedBuff.get().responseStatus.isSome():
    return err(decodedBuff.get().responseStatus.get())
  return ok(decodedBuff.get().response.get())

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64, peer: RemotePeerInfo
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  try:
    let connOpt = await wpx.peerManager.dialPeer(peer, WakuPeerExchangeCodec)
    if connOpt.isNone():
      return err(
        PeerExchangeResponseStatus(
          status: PeerExchangeResponseStatusCode.DIAL_FAILURE, desc: some(dialFailure)
        )
      )
    return await wpx.request(numPeers, connOpt.get())
  except CatchableError:
    return err(
      PeerExchangeResponseStatus(
        status: PeerExchangeResponseStatusCode.BAD_RESPONSE,
        desc: some("exception dialing peer: " & getCurrentExceptionMsg()),
      )
    )

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async: (raises: []).} =
  let peerOpt = wpx.peerManager.selectPeer(WakuPeerExchangeCodec)
  if peerOpt.isNone():
    waku_px_errors.inc(labelValues = [peerNotFoundFailure])
    return err(
      PeerExchangeResponseStatus(
        status: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        desc: some(peerNotFoundFailure),
      )
    )
  return await wpx.request(numPeers, peerOpt.get())

proc respond(
    wpx: WakuPeerExchange, enrs: seq[enr.Record], conn: Connection
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeResponse(enrs.mapIt(PeerExchangePeerInfo(enr: it.raw)))

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      PeerExchangeResponseStatus(
        status: PeerExchangeResponseStatusCode.DIAL_FAILURE,
        desc: some("exception dialing peer: " & exc.msg),
      )
    )

  return ok()

proc respondError(
    wpx: WakuPeerExchange,
    status: PeerExchangeResponseStatusCode,
    desc: Option[string],
    conn: Connection,
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc.makeErrorResponse(status, desc)

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(
      PeerExchangeResponseStatus(
        status: PeerExchangeResponseStatusCode.SERVICE_UNAVAILABLE,
        desc: some("exception dialing peer: " & exc.msg),
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
    trace "peer not from discv5", peer = $peer, origin = $peer.origin
    return false

  if peer.enr.isNone():
    trace "peer has no ENR", peer = $peer
    return false

  if cluster.isSome() and peer.enr.get().isClusterMismatched(cluster.get()):
    trace "peer has mismatching cluster", peer = $peer
    return false

  return true

proc populateEnrCache(wpx: WakuPeerExchange) =
  # share only peers that i) are reachable ii) come from discv5 iii) share cluster
  let withEnr =
    wpx.peerManager.peerStore.getReachablePeers().filterIt(poolFilter(wpx.cluster, it))

  # either what we have or max cache size
  var newEnrCache = newSeq[enr.Record](0)
  for i in 0 ..< min(withEnr.len, MaxPeersCacheSize):
    newEnrCache.add(withEnr[i].enr.get())

  # swap cache for new
  wpx.enrCache = newEnrCache

proc updatePxEnrCache(wpx: WakuPeerExchange) {.async.} =
  # try more aggressively to fill the cache at startup
  while wpx.enrCache.len < MaxPeersCacheSize:
    wpx.populateEnrCache()
    await sleepAsync(5.seconds)

  heartbeat "Updating px enr cache", CacheRefreshInterval:
    wpx.populateEnrCache()

proc initProtocolHandler(wpx: WakuPeerExchange) =
  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var buffer: seq[byte]
    wpx.requestRateLimiter.checkUsageLimit(WakuPeerExchangeCodec, conn):
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize.int)
      except CatchableError as exc:
        waku_px_errors.inc(labelValues = [exc.msg])
        discard await wpx.respondError(
          PeerExchangeResponseStatusCode.BAD_REQUEST, some(exc.msg), conn
        )
        return

      let decBuf = PeerExchangeRpc.decode(buffer)
      if decBuf.isErr() or decBuf.get().request.isNone():
        waku_px_errors.inc(labelValues = [decodeRpcFailure])
        discard await wpx.respondError(
          PeerExchangeResponseStatusCode.BAD_REQUEST, some($decBuf.error), conn
        )
        return

      let request = decBuf.get().request.get()
      trace "peer exchange request received"
      let enrs = wpx.getEnrsFromCache(request.numPeers)
      (await wpx.respond(enrs, conn)).isErrOr:
        waku_px_peers_sent.inc(enrs.len().int64())
    do:
      discard await wpx.respondError(
        PeerExchangeResponseStatusCode.TOO_MANY_REQUESTS, none(string), conn
      )

    # close, no data is expected
    await conn.closeWithEof()

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
