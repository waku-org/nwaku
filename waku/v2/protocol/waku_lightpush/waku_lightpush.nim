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
  ../message_notifier,
  waku_lightpush_types,
  ../../utils/requests,
  ../../node/peer_manager/peer_manager

export waku_lightpush_types

# TODO metrics
declarePublicGauge waku_lightpush_errors, "number of lightpush protocol errors", ["type"]

logScope:
  topics = "wakulightpush"

const
  WakuFilterCodec* = "/vac/waku/lightpush/2.0.0-alpha1"

# Encoding and decoding -------------------------------------------------------
proc encode*(rpc: PushRequest): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, rpc.pubsubTopic)
  result.write(2, rpc.message.encode())

proc init*(T: type PushRequest, buffer: seq[byte]): ProtoResult[T] =
  var rpc = PushRequest(pubsubTopic: "", message: WakuMessage())
  let pb = initProtoBuffer(buffer)

  var pubsubTopic: string
  discard ? pb.getField(1, pubsubTopic)
  rpc.pubsubTopic = pubsubTopic

  var message: seq[byte]
  discard ? pb.getRepeatedField(2, message)
  WakuMessage.init(message)
  rpc.message = message

  ok(rpc)

proc encode*(rpc: PushResponse): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, bool(rpc.isSuccess))
  result.write(2, rpc.info)

proc init*(T: type PushResponse, buffer: seq[byte]): ProtoResult[T] =
  var rpc = PushResponse(isSuccess: false, info: "")
  let pb = initProtoBuffer(buffer)

  var isSuccess: bool
  discard ? pb.getField(1, isSuccess)
  rpc.isSuccess = isSuccess

  var info: string
  discard ? pb.getField(2, info)
  rpc.info = info

  ok(rpc)

proc encode*(rpc: PushRPC): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, rpc.requestId)
  result.write(2, rpc.request.encode())
  result.write(3, rpc.response.encode())

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

  ok(rpc)

# Protocol -------------------------------------------------------
proc init*(T: type WakuLightPush, peerManager: PeerManager, rng: ref BrHmacDrbgContext, handler: PushRequestHandler): T =
  new result
  result.rng = crypto.newRng()
  result.peerManager = peerManager
  result.pushRequestHandler = handler
  result.init()

method init*(wlp: WakuLightPush) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = PushRPC.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
      return

    info "lightpush message received"

    let value = res.value
    if value.push != PushRequest():
      # TODO: This should deal with messages
      wlp.pushRequestHandler(value.requestId, value.push)
    if value.request != PushResponse():
      if value.response.isSuccessful:
        info "lightpush message success"
      else:
        info "lightpush message failure", info=value.response.info

  wlp.handler = handle
  wlp.codec = WakuLightPushCodec
