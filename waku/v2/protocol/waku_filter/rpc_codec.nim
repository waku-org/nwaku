{.push raises: [Defect].}

import
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../waku_message,
  ../../utils/protobuf,
  ./rpc


# Multiply by 10 for safety. Currently we never push more than 1 message at a time
# We add a 64kB safety buffer for protocol overhead.
const MaxRpcSize* = 10 * MaxWakuMessageSize + 64 * 1024


proc encode*(filter: ContentFilter): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, filter.contentTopic)
  output.finish3()

  return output

proc init*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var contentTopic: ContentTopic
  discard ?pb.getField(1, contentTopic)

  return ok(ContentFilter(contentTopic: contentTopic))


proc encode*(rpc: FilterRequest): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, uint64(rpc.subscribe))
  output.write3(2, rpc.pubSubTopic)

  for filter in rpc.contentFilters:
    output.write3(3, filter.encode())

  output.finish3()

  return output

proc init*(T: type FilterRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var rpc = FilterRequest(contentFilters: @[], pubSubTopic: "")

  var subflag: uint64
  if ?pb.getField(1, subflag):
    rpc.subscribe = bool(subflag)

  var pubSubTopic: string
  discard ?pb.getField(2, pubSubTopic)
  rpc.pubSubTopic = pubSubTopic

  var buffs: seq[seq[byte]]
  discard ?pb.getRepeatedField(3, buffs)
  for buf in buffs:
    rpc.contentFilters.add(?ContentFilter.init(buf))

  return ok(rpc)


proc encode*(push: MessagePush): ProtoBuffer =
  var output = initProtoBuffer()
  for push in push.messages:
    output.write3(1, push.encode())
  output.finish3()

  return output

proc init*(T: type MessagePush, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var push = MessagePush()

  var messages: seq[seq[byte]]
  discard ?pb.getRepeatedField(1, messages)

  for buf in messages:
    push.messages.add(?WakuMessage.init(buf))

  return ok(push)


proc encode*(rpc: FilterRPC): ProtoBuffer =
  var output = initProtoBuffer()
  output.write3(1, rpc.requestId)
  output.write3(2, rpc.request.encode())
  output.write3(3, rpc.push.encode())
  output.finish3()

  return output

proc init*(T: type FilterRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer) 

  var rpc = FilterRPC()

  var requestId: string
  discard ?pb.getField(1, requestId)
  rpc.requestId = requestId

  var requestBuffer: seq[byte]
  discard ?pb.getField(2, requestBuffer)
  rpc.request = ?FilterRequest.init(requestBuffer)

  var pushBuffer: seq[byte]
  discard ?pb.getField(3, pushBuffer)
  rpc.push = ?MessagePush.init(pushBuffer)

  return ok(rpc)
