when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  std/options
import
  ../../../common/protobuf,
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
  if not ?pb.getField(1, pubSubTopic):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.pubSubTopic = pubSubTopic

  var messageBuf: seq[byte]
  if not ?pb.getField(2, messageBuf):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.message = ?WakuMessage.decode(messageBuf)

  ok(rpc)


proc encode*(rpc: PushResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, uint64(rpc.isSuccess))
  pb.write3(2, rpc.info)
  pb.finish3()

  pb

proc decode*(T: type PushResponse, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PushResponse()

  var isSuccess: uint64
  if not ?pb.getField(1, isSuccess):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.isSuccess = bool(isSuccess)

  var info: string
  if not ?pb.getField(2, info):
    rpc.info = none(string)
  else: 
    rpc.info = some(info)

  ok(rpc)


proc encode*(rpc: PushRPC): ProtoBuffer =
  var pb = initProtoBuffer()
  
  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.request.map(encode))
  pb.write3(3, rpc.response.map(encode))
  pb.finish3()

  pb

proc decode*(T: type PushRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = PushRPC()

  var requestId: string
  if not ?pb.getField(1, requestId):
    return err(ProtoError.RequiredFieldMissing)
  else:
    rpc.requestId = requestId

  var requestBuffer: seq[byte]
  if not ?pb.getField(2, requestBuffer):
    rpc.request = none(PushRequest)
  else:
    let request = ?PushRequest.decode(requestBuffer)
    rpc.request = some(request)

  var responseBuffer: seq[byte]
  if not ?pb.getField(3, responseBuffer):
    rpc.response = none(PushResponse)
  else:
    let response = ?PushResponse.decode(responseBuffer)
    rpc.response = some(response)

  ok(rpc)