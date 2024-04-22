import
  std/[options, sequtils, random],
  stew/results,
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
  ./rpc_codec

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
  CacheRefreshInterval = 15.minutes

  WakuPeerExchangeCodec* = "/vac/waku/peer-exchange/2.0.0-alpha1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  peerNotFoundFailure = "peer_not_found_failure"
  decodeRpcFailure = "decode_rpc_failure"
  retrievePeersDiscv5Error = "retrieve_peers_discv5_failure"
  pxFailure = "px_failure"

type
  WakuPeerExchangeResult*[T] = Result[T, string]

  WakuPeerExchange* = ref object of LPProtocol
    peerManager*: PeerManager
    enrCache*: seq[enr.Record]
      # todo: next step: ring buffer; future: implement cache satisfying https://rfc.vac.dev/spec/34/

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64, conn: Connection
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc(request: PeerExchangeRequest(numPeers: numPeers))

  var buffer: seq[byte]
  var error: string
  try:
    await conn.writeLP(rpc.encode().buffer)
    buffer = await conn.readLp(DefaultMaxRpcSize.int)
  except CatchableError as exc:
    waku_px_errors.inc(labelValues = [exc.msg])
    error = $exc.msg
  finally:
    # close, no more data is expected
    await conn.closeWithEof()

  if error.len > 0:
    return err("write/read failed: " & error)

  let decodedBuff = PeerExchangeRpc.decode(buffer)
  if decodedBuff.isErr():
    return err("decode failed: " & $decodedBuff.error)
  return ok(decodedBuff.get().response)

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64, peer: RemotePeerInfo
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async, gcsafe.} =
  let connOpt = await wpx.peerManager.dialPeer(peer, WakuPeerExchangeCodec)
  if connOpt.isNone():
    return err(dialFailure)
  return await wpx.request(numPeers, connOpt.get())

proc request*(
    wpx: WakuPeerExchange, numPeers: uint64
): Future[WakuPeerExchangeResult[PeerExchangeResponse]] {.async, gcsafe.} =
  let peerOpt = wpx.peerManager.selectPeer(WakuPeerExchangeCodec)
  if peerOpt.isNone():
    waku_px_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)
  return await wpx.request(numPeers, peerOpt.get())

proc respond(
    wpx: WakuPeerExchange, enrs: seq[enr.Record], conn: Connection
): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc(
    response:
      PeerExchangeResponse(peerInfos: enrs.mapIt(PeerExchangePeerInfo(enr: it.raw)))
  )

  try:
    await conn.writeLP(rpc.encode().buffer)
  except CatchableError as exc:
    waku_px_errors.inc(labelValues = [exc.msg])
    return err(exc.msg)

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

proc populateEnrCache(wpx: WakuPeerExchange) =
  # share only peers that i) are reachable ii) come from discv5
  let withEnr = wpx.peerManager.peerStore
    .getReachablePeers()
    .filterIt(it.origin == Discv5)
    .filterIt(it.enr.isSome)

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
    try:
      buffer = await conn.readLp(DefaultMaxRpcSize.int)
    except CatchableError as exc:
      waku_px_errors.inc(labelValues = [exc.msg])
      return

    let decBuf = PeerExchangeRpc.decode(buffer)
    if decBuf.isErr():
      waku_px_errors.inc(labelValues = [decodeRpcFailure])
      return

    let rpc = decBuf.get()
    trace "peer exchange request received"
    let enrs = wpx.getEnrsFromCache(rpc.request.numPeers)
    let res = await wpx.respond(enrs, conn)
    if res.isErr:
      waku_px_errors.inc(labelValues = [res.error])
    else:
      waku_px_peers_sent.inc(enrs.len().int64())

    # close, no data is expected
    await conn.closeWithEof()

  wpx.handler = handler
  wpx.codec = WakuPeerExchangeCodec

proc new*(T: type WakuPeerExchange, peerManager: PeerManager): T =
  let wpx = WakuPeerExchange(peerManager: peerManager)
  wpx.initProtocolHandler()
  asyncSpawn wpx.updatePxEnrCache()
  return wpx
