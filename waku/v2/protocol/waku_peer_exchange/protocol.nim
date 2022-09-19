import
  std/[options, sets, tables, sequtils, random],
  stew/results,
  chronicles,
  chronos,
  metrics,
  libp2p/protocols/protocol,
  libp2p/crypto/crypto,
  eth/p2p/discoveryv5/enr
import
  ../../node/peer_manager/peer_manager,
  ../../node/discv5/waku_discv5,
  ../../utils/requests,
  ../waku_message,
  ../waku_relay,
  ./rpc,
  ./rpc_codec


declarePublicGauge waku_px_peers, "number of peers (in the node's peerManager) supporting the peer exchange protocol"
declarePublicGauge waku_px_peers_received_total, "number of ENRs received via peer exchange"
declarePublicGauge waku_px_peers_received_unknown, "number of previously unknown ENRs received via peer exchange"
declarePublicGauge waku_px_peers_sent, "number of ENRs sent to peer exchange requesters"
declarePublicGauge waku_px_peers_cached, "number of peer exchange peer ENRs cached"
declarePublicGauge waku_px_errors, "number of peer exchange errors", ["type"]

logScope:
  topics = "wakupx"


const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety
  MaxRpcSize = 10 * MaxWakuMessageSize + 64 * 1024 # TODO what is the expected size of a PX message? As currently specified, it can contain an arbitary number of ENRs...
  MaxCacheSize = 1000
  CacheCleanWindow = 200

  WakuPeerExchangeCodec* = "/vac/waku/peer-exchange/2.0.0-alpha1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  peerNotFoundFailure = "peer_not_found_failure"
  decodeRpcFailure = "decode_rpc_failure"
  retrievePeersDiscv5Error= "retrieve_peers_discv5_failure"
  pxFailure = "px_failure"

type
  WakuPeerExchangeResult*[T] = Result[T, string]

  WakuPeerExchange* = ref object of LPProtocol
    peerManager*: PeerManager
    wakuDiscv5: Option[WakuDiscoveryV5]
    enrCache: seq[enr.Record] # todo: next step: ring buffer; future: implement cache satisfying https://rfc.vac.dev/spec/34/

proc sendPeerExchangeRpcToPeer(wpx: WakuPeerExchange, rpc: PeerExchangeRpc, peer: RemotePeerInfo | PeerId): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let connOpt = await wpx.peerManager.dialPeer(peer, WakuPeerExchangeCodec)
  if connOpt.isNone():
    return err(dialFailure)

  let connection = connOpt.get()

  await connection.writeLP(rpc.encode().buffer)

  return ok()

proc request(wpx: WakuPeerExchange, numPeers: uint64, peer: RemotePeerInfo): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let rpc = PeerExchangeRpc(
    request: PeerExchangeRequest(
      numPeers: numPeers
    )
  )

  let res = await wpx.sendPeerExchangeRpcToPeer(rpc, peer)
  if res.isErr():
    waku_px_errors.inc(labelValues = [res.error()])
    return err(res.error())

  return ok()

proc request*(wpx: WakuPeerExchange, numPeers: uint64): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let peerOpt = wpx.peerManager.selectPeer(WakuPeerExchangeCodec)
  if peerOpt.isNone():
    waku_px_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)

  return await wpx.request(numPeers, peerOpt.get())

proc respond(wpx: WakuPeerExchange, enrs: seq[enr.Record], peer: RemotePeerInfo | PeerId): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  var peerInfos: seq[PeerExchangePeerInfo] = @[]
  for e in enrs:
    let pi = PeerExchangePeerInfo(
      enr: e.raw
    )
    peerInfos.add(pi)

  let rpc = PeerExchangeRpc(
    response: PeerExchangeResponse(
      peerInfos: peerInfos
    )
  )

  let res = await wpx.sendPeerExchangeRpcToPeer(rpc, peer)
  if res.isErr():
    waku_px_errors.inc(labelValues = [res.error()])
    return err(res.error())

  return ok()

proc respond*(wpx: WakuPeerExchange, enrs: seq[enr.Record]): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.} =
  let peerOpt = wpx.peerManager.selectPeer(WakuPeerExchangeCodec)
  if peerOpt.isNone():
    waku_px_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)

  return await wpx.respond(enrs, peerOpt.get())

proc cleanCache(px: WakuPeerExchange) {.gcsafe.} =
  px.enrCache.delete(0, CacheCleanWindow-1)

proc runPeerExchangeDiscv5Loop*(px: WakuPeerExchange) {.async, gcsafe.} =
  ## Runs a discv5 loop adding new peers to the px peer cache
  if px.wakuDiscv5.isNone():
    warn "Trying to run discovery v5 (for PX) while it's disabled"
    return

  info "Starting peer exchange discovery v5 loop"

  while px.wakuDiscv5.get().listening:
    trace "Running px discv5 discovery loop"
    let discoveredPeers = await px.wakuDiscv5.get().findRandomPeers()
    info "Discovered px peers via discv5", count=discoveredPeers.get().len()
    if discoveredPeers.isOk:
      for dp in discoveredPeers.get():
        if dp.enr.isSome() and not px.enrCache.contains(dp.enr.get()):
          px.enrCache.add(dp.enr.get())

    if px.enrCache.len() >= MaxCacheSize:
      px.cleanCache()

    ## This loop "competes" with the loop in wakunode2
    ## For the purpose of collecting px peers, 30 sec intervals should be enough
    await sleepAsync(30.seconds)

proc getEnrsFromCache(px: WakuPeerExchange, numPeers: uint64): seq[enr.Record] {.gcsafe.} =
  randomize()
  if px.enrCache.len() == 0:
    debug "peer exchange ENR cache is empty"
    return @[]
  for i in 0..<min(numPeers, px.enrCache.len().uint64()):
    let ri = rand(0..<px.enrCache.len())
    result.add(px.enrCache[ri])

proc initProtocolHandler*(px: WakuPeerExchange) =

  proc handler(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let message = await conn.readLp(MaxRpcSize.int)

    let res = PeerExchangeRpc.init(message)
    if res.isErr():
      waku_px_errors.inc(labelValues = [decodeRpcFailure])
      return

    let rpc = res.get()

    # handle peer exchange request
    if rpc.request != PeerExchangeRequest():
      trace "peer exchange request received"
      let enrs = px.getEnrsFromCache(rpc.request.numPeers)
      discard await px.respond(enrs, conn.peerId)
      waku_px_peers_sent.inc(enrs.len().int64())

    # handle peer exchange response
    if rpc.response != PeerExchangeResponse():
      # todo: error handling
      trace "peer exchange response received"
      var record: enr.Record
      var remotePeerInfoList: seq[RemotePeerInfo]
      waku_px_peers_received_total.inc(rpc.response.peerInfos.len().int64())
      for pi in rpc.response.peerInfos:
        discard enr.fromBytes(record, pi.enr)
        remotePeerInfoList.add(record.toRemotePeerInfo().get)

      let newPeers = remotePeerInfoList.filterIt(
        not px.peerManager.switch.isConnected(it.peerId))

      if newPeers.len() > 0:
        waku_px_peers_received_unknown.inc(newPeers.len().int64())
        debug "Connecting to newly discovered peers", count=newPeers.len()
        await px.peerManager.connectToNodes(newPeers, WakuRelayCodec, source = "peer exchange")

  px.handler = handler
  px.codec = WakuPeerExchangeCodec

proc init*(T: type WakuPeerExchange,
            peerManager: PeerManager,
            wakuDiscv5: Option[WakuDiscoveryV5] = none(WakuDiscoveryV5)
          ): T =
  let px = WakuPeerExchange(
    peerManager: peerManager,
    wakuDiscv5: wakuDiscv5
  )
  px.initProtocolHandler()
  return px

proc setPeer*(wpx: WakuPeerExchange, peer: RemotePeerInfo) =
  wpx.peerManager.addPeer(peer, WakuPeerExchangeCodec)
  waku_px_peers.inc()

