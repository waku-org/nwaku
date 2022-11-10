when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../../utils/protobuf,
  ../waku_message,
  ./rpc


# Multiply by 10 for safety. Currently we never push more than 1 message at a time
# We add a 64kB safety buffer for protocol overhead.
const MaxRpcSize* = 10 * MaxWakuMessageSize + 64 * 1024


proc encode*(filter: ContentFilter): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, filter.contentTopic)
  pb.finish3()

  pb

proc decode*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var contentTopic: ContentTopic
  discard ?pb.getField(1, contentTopic)

  ok(ContentFilter(contentTopic: contentTopic))


proc encode*(rpc: FilterRequest): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, uint64(rpc.subscribe))
  pb.write3(2, rpc.pubSubTopic)

  for filter in rpc.contentFilters:
    pb.write3(3, filter.encode())

  pb.finish3()

  pb

proc decode*(T: type FilterRequest, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var rpc = FilterRequest(contentFilters: @[], pubSubTopic: "")

  var subflag: uint64
  if ?pb.getField(1, subflag):
    rpc.subscribe = bool(subflag)

  var pubSubTopic: PubsubTopic
  discard ?pb.getField(2, pubSubTopic)
  rpc.pubSubTopic = pubSubTopic

  var buffs: seq[seq[byte]]
  discard ?pb.getRepeatedField(3, buffs)
  for buf in buffs:
    rpc.contentFilters.add(?ContentFilter.decode(buf))

  ok(rpc)


proc encode*(push: MessagePush): ProtoBuffer =
  var pb = initProtoBuffer()

  for push in push.messages:
    pb.write3(1, push.encode())

  pb.finish3()

  pb

proc decode*(T: type MessagePush, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)
  var push = MessagePush()

  var messages: seq[seq[byte]]
  discard ?pb.getRepeatedField(1, messages)

  for buf in messages:
    push.messages.add(?WakuMessage.decode(buf))

  ok(push)


proc encode*(rpc: FilterRPC): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write3(1, rpc.requestId)
  pb.write3(2, rpc.request.encode())
  pb.write3(3, rpc.push.encode())
  pb.finish3()

  pb

proc decode*(T: type FilterRPC, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer) 
  var rpc = FilterRPC()

  var requestId: string
  discard ?pb.getField(1, requestId)
  rpc.requestId = requestId

  var requestBuffer: seq[byte]
  discard ?pb.getField(2, requestBuffer)
  rpc.request = ?FilterRequest.decode(requestBuffer)

  var pushBuffer: seq[byte]
  discard ?pb.getField(3, pushBuffer)
  rpc.push = ?MessagePush.decode(pushBuffer)

  ok(rpc)
