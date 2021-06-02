import
  std/[tables, sequtils, options],
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  ../../utils/requests,
  ../../node/peer_manager/peer_manager,
  ../message_notifier,
  ../waku_relay,
  waku_keepalive_types

export waku_keepalive_types

declarePublicGauge waku_keepalive_count, "number of keepalives received"
declarePublicGauge waku_keepalive_errors, "number of keepalive protocol errors", ["type"]

logScope:
  topics = "wakukeepalive"

const
  WakuKeepaliveCodec* = "/vac/waku/keepalive/2.0.0-alpha1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"

# Encoding and decoding -------------------------------------------------------
proc encode*(msg: KeepaliveMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  # @TODO: Currently no fields defined for a KeepaliveMessage

  return pb

proc init*(T: type KeepaliveMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = KeepaliveMessage()
  let pb = initProtoBuffer(buffer)

  # @TODO: Currently no fields defined for a KeepaliveMessage

  ok(msg)

# Protocol -------------------------------------------------------
proc new*(T: type WakuKeepalive, peerManager: PeerManager, rng: ref BrHmacDrbgContext): T =
  debug "new WakuKeepalive"
  var wk: WakuKeepalive
  new wk

  wk.rng = crypto.newRng()
  wk.peerManager = peerManager
  
  wk.init()

  return wk

method init*(wk: WakuKeepalive) =
  debug "init WakuKeepalive"

  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    info "WakuKeepalive message received"
    waku_keepalive_count.inc()

  wk.handler = handle
  wk.codec = WakuKeepaliveCodec

proc keepAllAlive*(wk: WakuKeepalive) {.async, gcsafe.} =
  # Send keepalive message to all managed and connected peers
  let peers = wk.peerManager.peers().filterIt(wk.peerManager.connectedness(it.peerId) == Connected).mapIt(it.toPeerInfo())

  for peer in peers:
    let connOpt = await wk.peerManager.dialPeer(peer, WakuKeepaliveCodec)

    if connOpt.isNone():
      # @TODO more sophisticated error handling here
      error "failed to connect to remote peer"
      waku_keepalive_errors.inc(labelValues = [dialFailure])
      return

    await connOpt.get().writeLP(KeepaliveMessage().encode().buffer)  # Send keep-alive on connection
