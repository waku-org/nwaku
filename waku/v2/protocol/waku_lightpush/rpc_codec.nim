when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  libp2p/protobuf/minprotobuf
import
  ../../utils/protobuf,
  ../waku_message,
  ./rpc


const MaxRpcSize* = MaxWakuMessageSize + 64 * 1024 # We add a 64kB safety buffer for protocol overhead


proc encode*(rpc: PushRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.pubSubTopic)
  pb.write3(2, rpc.message.encode())
  pb.finish3()

  pb

proc decode*(T: type PushRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PushRequest()

  var pubSubTopic: PubsubTopic
  discard ?pb.getField(1, pubSubTopic)
  rpc.pubSubTopic = pubSubTopic

  var buf: seq[byte]
  discard ?pb.getField(2, buf)
  rpc.message = ?WakuMessage.decode(buf)

  ok(rpc)


proc encode*(rpc: PushResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, uint64(rpc.isSuccess))
  pb.write3(2, rpc.info)
  pb.finish3()

  pb

proc decode*(T: type PushResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PushResponse(isSuccess: false, info: "")

  var isSuccess: uint64
  if ?pb.getField(1, isSuccess):
    rpc.isSuccess = bool(isSuccess)

  var info: string
  discard ?pb.getField(2, info)
  rpc.info = info

  ok(rpc)


proc encode*(rpc: PushRPC): ProtoBuffer =
  var pb = initProtoBuffer()
  
  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.request.encode())
  pb.write3(3, rpc.response.encode())
  pb.finish3()

  pb

proc decode*(T: type PushRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PushRPC()

  var requestId: string
  discard ?pb.getField(1, requestId)
  rpc.requestId = requestId

  var requestBuffer: seq[byte]
  discard ?pb.getField(2, requestBuffer)
  rpc.request = ?PushRequest.decode(requestBuffer)

  var pushBuffer: seq[byte]
  discard ?pb.getField(3, pushBuffer)
  rpc.response = ?PushResponse.decode(pushBuffer)

  ok(rpc)