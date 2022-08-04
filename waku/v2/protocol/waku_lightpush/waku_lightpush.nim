{.push raises: [Defect].}

import
  std/[tables, options],
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  waku_lightpush_types,
  ../../utils/requests,
  ../../utils/protobuf,
  ../../node/peer_manager/peer_manager,
  ../waku_relay

export waku_lightpush_types

declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_lightpush_errors, "number of lightpush protocol errors", ["type"]
declarePublicGauge waku_lightpush_messages, "number of lightpush messages received", ["type"]

logScope:
  topics = "wakulightpush"

const
  WakuLightPushCodec* = "/vac/waku/lightpush/2.0.0-beta1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

# Encoding and decoding -------------------------------------------------------
proc encode*(rpc: PushRequest): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, rpc.pubSubTopic)
  output.write3(2, rpc.message.encode())

  output.finish3()

  return output

proc init*(T: type PushRequest, buffer: seq[byte]): ProtoResult[T] =
  #var rpc = PushRequest(pubSubTopic: "", message: WakuMessage())
  var rpc = PushRequest()
  let pb = initProtoBuffer(buffer)

  var pubSubTopic: string
  discard ? pb.getField(1, pubSubTopic)
  rpc.pubSubTopic = pubSubTopic

  var buf: seq[byte]
  discard ? pb.getField(2, buf)
  rpc.message = ? WakuMessage.init(buf)

  return ok(rpc)

proc encode*(rpc: PushResponse): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, uint64(rpc.isSuccess))
  output.write3(2, rpc.info)

  output.finish3()

  return output

proc init*(T: type PushResponse, buffer: seq[byte]): ProtoResult[T] =
  var rpc = PushResponse(isSuccess: false, info: "")
  let pb = initProtoBuffer(buffer)

  var isSuccess: uint64
  if ? pb.getField(1, isSuccess):
    rpc.isSuccess = bool(isSuccess)

  var info: string
  discard ? pb.getField(2, info)
  rpc.info = info

  return ok(rpc)

proc encode*(rpc: PushRPC): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, rpc.requestId)
  output.write3(2, rpc.request.encode())
  output.write3(3, rpc.response.encode())

  output.finish3()

  return output

proc init*(T: type PushRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = PushRPC()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, rpc.requestId)

  var requestBuffer: seq[byte]
  discard ? pb.getField(2, requestBuffer)

  rpc.request = ? PushRequest.init(requestBuffer)

  var pushBuffer: seq[byte]
  discard ? pb.getField(3, pushBuffer)

  rpc.response = ? PushResponse.init(pushBuffer)

  return ok(rpc)

# Protocol -------------------------------------------------------
proc init*(T: type WakuLightPush, peerManager: PeerManager, rng: ref BrHmacDrbgContext, handler: PushRequestHandler, relay: WakuRelay = nil): T =
  debug "init"
  let rng = crypto.newRng()
  var wl = WakuLightPush(rng: rng,
                        peerManager: peerManager, 
                        requestHandler: handler, 
                        relayReference: relay)
  wl.init()
  
  return wl

proc setPeer*(wlp: WakuLightPush, peer: RemotePeerInfo) =
  wlp.peerManager.addPeer(peer, WakuLightPushCodec)
  waku_lightpush_peers.inc()

method init*(wlp: WakuLightPush) =
  debug "init"
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(MaxRpcSize.int)
    var res = PushRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
      return

    info "lightpush message received"

    let value = res.value
    if value.request != PushRequest():
      info "lightpush push request"
      waku_lightpush_messages.inc(labelValues = ["PushRequest"])
      let
        pubSubTopic = value.request.pubSubTopic
        message = value.request.message
      debug "PushRequest", pubSubTopic=pubSubTopic, msg=message
      var response: PushResponse
      if wlp.relayReference != nil:
        let wakuRelay = wlp.relayReference
        let data = message.encode().buffer
        # XXX Assumes success, should probably be extended to check for network, peers, etc
        discard wakuRelay.publish(pubSubTopic, data)
        response = PushResponse(is_success: true, info: "Totally.")
      else:
        debug "No relay protocol present, unsuccesssful push"
        response = PushResponse(is_success: false, info: "No relay protocol")
      await conn.writeLp(PushRPC(requestId: value.requestId,
      response: response).encode().buffer)
      #wlp.requestHandler(value.requestId, value.request)
    if value.response != PushResponse():
      waku_lightpush_messages.inc(labelValues = ["PushResponse"])
      if value.response.isSuccess:
        info "lightpush message success"
      else:
        info "lightpush message failure", info=value.response.info

  wlp.handler = handle
  wlp.codec = WakuLightPushCodec

proc request*(w: WakuLightPush, request: PushRequest, handler: PushResponseHandler) {.async, gcsafe.} =
  let peerOpt = w.peerManager.selectPeer(WakuLightPushCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return

  let connOpt = await w.peerManager.dialPeer(peerOpt.get(), WakuLightPushCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return

  await connOpt.get().writeLP(PushRPC(requestId: generateRequestId(w.rng),
                                      request: request).encode().buffer)

  var message = await connOpt.get().readLp(64*1024)
  let response = PushRPC.init(message)

  if response.isErr:
    error "failed to decode response"
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return

  handler(response.value.response)
