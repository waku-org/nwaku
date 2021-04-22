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

  rpc.push = ? PushResponse.init(pushBuffer)

  ok(rpc)
