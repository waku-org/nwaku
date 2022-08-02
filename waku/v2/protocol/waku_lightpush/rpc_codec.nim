{.push raises: [Defect].}


import
  libp2p/protobuf/minprotobuf
import
  ../waku_message,
  ../../utils/protobuf,
  ./rpc


proc encode*(rpc: PushRequest): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, rpc.pubSubTopic)
  output.write3(2, rpc.message.encode())
  output.finish3()

  return output

proc init*(T: type PushRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PushRequest()

  var pubSubTopic: string
  discard ?pb.getField(1, pubSubTopic)
  rpc.pubSubTopic = pubSubTopic

  var buf: seq[byte]
  discard ?pb.getField(2, buf)
  rpc.message = ?WakuMessage.init(buf)

  return ok(rpc)


proc encode*(rpc: PushResponse): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, uint64(rpc.isSuccess))
  output.write3(2, rpc.info)
  output.finish3()

  return output

proc init*(T: type PushResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = PushResponse(isSuccess: false, info: "")

  var isSuccess: uint64
  if ?pb.getField(1, isSuccess):
    rpc.isSuccess = bool(isSuccess)

  var info: string
  discard ?pb.getField(2, info)
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
  let pb = initProtoBuffer(buffer)

  var rpc = PushRPC()

  var requestId: string
  discard ?pb.getField(1, requestId)
  rpc.requestId = requestId

  var requestBuffer: seq[byte]
  discard ?pb.getField(2, requestBuffer)
  rpc.request = ?PushRequest.init(requestBuffer)

  var pushBuffer: seq[byte]
  discard ?pb.getField(3, pushBuffer)
  rpc.response = ?PushResponse.init(pushBuffer)

  return ok(rpc)