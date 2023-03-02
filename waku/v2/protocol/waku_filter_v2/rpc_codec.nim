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

const
  MaxSubscribeSize* = 10 * MaxWakuMessageSize + 64*1024 # We add a 64kB safety buffer for protocol overhead
  MaxPushSize* = 10 * MaxWakuMessageSize + 64*1024 # We add a 64kB safety buffer for protocol overhead

proc encode*(rpc: FilterSubscribeRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, uint32(ord(rpc.filterSubscribeType)))

  pb.write3(10, rpc.pubsubTopic)

  for contentTopic in rpc.contentTopics:
    pb.write3(11, contentTopic)

  pb

proc decode*(T: type FilterSubscribeRequest, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterSubscribeRequest()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  var filterSubscribeType: uint32
  if not ?pb.getField(2, filterSubscribeType):
    return err(ProtobufError.missingRequiredField("filter_subscribe_type"))
  else:
    rpc.filterSubscribeType = FilterSubscribeType(filterSubscribeType)

  var pubsubTopic: PubsubTopic
  if not ?pb.getField(10, pubsubTopic):
    rpc.pubsubTopic = none(PubsubTopic)
  else:
    rpc.pubsubTopic = some(pubsubTopic)

  discard ?pb.getRepeatedField(11, rpc.contentTopics)

  ok(rpc)

proc encode*(rpc: FilterSubscribeResponse): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.statusCode)
  pb.write3(3, rpc.statusDesc)

  pb

proc decode*(T: type FilterSubscribeResponse, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterSubscribeResponse()

  if not ?pb.getField(1, rpc.requestId):
    return err(ProtobufError.missingRequiredField("request_id"))

  if not ?pb.getField(2, rpc.statusCode):
    return err(ProtobufError.missingRequiredField("status_code"))

  if not ?pb.getField(3, rpc.statusDesc):
    rpc.statusDesc = none(string)
  else:
    rpc.statusDesc = some(rpc.statusDesc.get())

  ok(rpc)
