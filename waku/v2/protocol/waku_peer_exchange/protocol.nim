import
  std/[options, sets, tables, sequtils],
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
  ./rpc,
  ./rpc_codec


declarePublicGauge waku_px_peers, "number of peers (in the node's peerManager) supporting the peer exchange protocol"
declarePublicGauge waku_px_peers_received, "number of px peer ENRs received"
declarePublicGauge waku_px_peers_sent, "number of px peer ENRs sent to requesters"
declarePublicGauge waku_px_peers_cached, "number of px peers ENRs cached"
declarePublicGauge waku_px_errors, "number of peer exchange errors", ["type"]

logScope:
  topics = "wakupx"


const
  # We add a 64kB safety buffer for protocol overhead.
  # 10x-multiplier also for safety
  MaxRpcSize* = 10 * MaxWakuMessageSize + 64 * 1024 # TODO what is the expected size of a PX message? As currently specified, it can contain an arbitary number of ENRs...

  WakuPeerExchangeCodec* = "/vac/waku/peer-exchange/2.0.0-alpha1"

# TODO: use WakuPeerExchangeError type (enum)
# Error types (metric label values)
const
  dialFailure = "dial_failure"
  peerNotFoundFailure = "peer_not_found_failure"
  decodeRpcFailure = "decode_rpc_failure"
  pxFailure = "px_failure"

type
  # WakuPeerExchangeError* {.pure.} = enum
  #   DecodeRpcFailure
  #   PxFailure
  #   PeerNotFoundFailure

  WakuPeerExchangeResult*[T] = Result[T, string] # TODO use WakuPeerExchangeError as the error type

  WakuPeerExchange* = ref object of LPProtocol
    peerManager*: PeerManager
    wakuDiscv5: Option[WakuDiscoveryV5]
    peerCache: Option[seq[enr.Record]] # todo: implement cache satisfying https://rfc.vac.dev/spec/34/
    # timeout*: chronos.Duration

proc sendPeerExchangeRpcToPeer(wpx: WakuPeerExchange, rpc: PeerExchangeRpc, peer: RemotePeerInfo | PeerId): Future[WakuPeerExchangeResult[void]] {.async, gcsafe.}=
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

proc getEnrsDiscv5(px: WakuPeerExchange, numPeers: uint64): Future[seq[enr.Record]] {.async, gcsafe.} =
  if px.wakuDiscv5.isNone():
    debug "discv5 not enabled: peer exchange peers cannot be retrieved via discv5"
    return @[] # Make this a result and return a proper err
  var enrs: seq[enr.Record]
  let discoveredPeers = await px.wakuDiscv5.get().findRandomPeers()
  if discoveredPeers.isOk:
    for dp in discoveredPeers.get():
      if dp.enr.isSome():
        enrs.add(dp.enr.get())
  return enrs

proc init(px: WakuPeerExchange) =

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
      let enrs = await px.getEnrsDiscv5(rpc.request.numPeers)
      discard await px.respond(enrs, conn.peerId)

    # handle peer exchange response
    if rpc.response != PeerExchangeResponse():
      # todo: error handling
      trace "peer exchange response received"
      var record: enr.Record
      for pi in rpc.response.peerInfos:
        discard enr.fromBytes(record, pi.enr)
        px.peerManager.addPeer(record.toRemotePeerInfo().get(), "/vac/waku/relay/2.0.0")

  px.handler = handler
  px.codec = WakuPeerExchangeCodec

  # # get nodes via discV5
  # # todo/discuss: we could start another discv5 loop here that manages and updates the cache.
  # # This would "compete" with the discv5 loop in wakunode2, which gets relay peers for the node itself
  # # Problem: Especially if there are not enough nodes in the network,
  # # retrieved nodes might already be in one of the peer sets managed by relay.
  # # We need to check that these peers are unused.
  # # If we cache these peers, we also have to check in the relay discv5 loop that retrieved peers are not yet in the PX cache.
  # # We could also ignore this, because for large networks, such collisions should be pacceptable (discuss)
  # if px.wakuDiscv5.isSome():
  #   trace "retrieving PX peers via discV5"

proc init*(T: type WakuPeerExchange,
            peerManager: PeerManager,
            wakuDiscv5: Option[WakuDiscoveryV5] = none(WakuDiscoveryV5)
          ): T =
  let px = WakuPeerExchange(
    peerManager: peerManager,
    wakuDiscv5: wakuDiscv5
  )
  px.init()
  return px

proc setPeer*(wpx: WakuPeerExchange, peer: RemotePeerInfo) =
  wpx.peerManager.addPeer(peer, WakuPeerExchangeCodec)
  waku_px_peers.inc()

