when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options
import
  ../common/protobuf,
  ../waku_core,
  ./rpc


# Multiply by 10 for safety. Currently we never push more than 1 message at a time
# We add a 64kB safety buffer for protocol overhead.
const MaxRpcSize* = 10 * MaxWakuMessageSize + 64 * 1024


proc encode*(filter: ContentFilter): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, filter.contentTopic)
  pb.finish3()

  pb

proc decode*(T: type ContentFilter, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = ContentFilter()

  var topic: string
  if not ?pb.getField(1, topic):
    return err(ProtobufError.missingRequiredField("content_topic"))
  else:
    rpc.contentTopic = topic

  ok(rpc)


proc encode*(rpc: FilterRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.subscribe)
  pb.write3(2, rpc.pubSubTopic)

  for filter in rpc.contentFilters:
    pb.write3(3, filter.encode())

  pb.finish3()

  pb

proc decode*(T: type FilterRequest, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterRequest()

  var subflag: uint64
  if not ?pb.getField(1, subflag):
    return err(ProtobufError.missingRequiredField("subscribe"))
  else:
    rpc.subscribe = bool(subflag)

  var topic: string
  if not ?pb.getField(2, topic):
    return err(ProtobufError.missingRequiredField("topic"))
  else:
    rpc.pubsubTopic = topic

  var buffs: seq[seq[byte]]
  if not ?pb.getRepeatedField(3, buffs):
    return err(ProtobufError.missingRequiredField("content_filters"))
  else:
    for buf in buffs:
      let filter = ?ContentFilter.decode(buf)
      rpc.contentFilters.add(filter)

  ok(rpc)


proc encode*(push: MessagePush): ProtoBuffer =
  var pb = initProtoBuffer()

  for push in push.messages:
    pb.write3(1, push.encode())

  pb.finish3()

  pb

proc decode*(T: type MessagePush, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = MessagePush()

  var messages: seq[seq[byte]]
  if not ?pb.getRepeatedField(1, messages):
    return err(ProtobufError.missingRequiredField("messages"))
  else:
    for buf in messages:
      let msg = ?WakuMessage.decode(buf)
      rpc.messages.add(msg)

  ok(rpc)


proc encode*(rpc: FilterRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.request.map(encode))
  pb.write3(3, rpc.push.map(encode))
  pb.finish3()

  pb

proc decode*(T: type FilterRPC, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterRPC()

  var requestId: string
  if not ?pb.getField(1, requestId):
    return err(ProtobufError.missingRequiredField("request_id"))
  else:
    rpc.requestId = requestId

  var requestBuffer: seq[byte]
  if not ?pb.getField(2, requestBuffer):
    rpc.request = none(FilterRequest)
  else:
    let request = ?FilterRequest.decode(requestBuffer)
    rpc.request = some(request)

  var pushBuffer: seq[byte]
  if not ?pb.getField(3, pushBuffer):
    rpc.push = none(MessagePush)
  else:
    let push = ?MessagePush.decode(pushBuffer)
    rpc.push = some(push)

  ok(rpc)
