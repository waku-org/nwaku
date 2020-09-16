import
  std/tables,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ./message_notifier,
  ./../../node/v2/[waku_message, waku_types]

# NOTE This is just a start, the design of this protocol isn't done yet. It
# should be direct payload exchange (a la req-resp), not be coupled with the
# relay protocol.

logScope:
  topics = "wakufilter"

const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-alpha5"

type
  ContentFilter* = object
    topics*: seq[string]

  FilterRequest* = object
    contentFilter*: seq[ContentFilter] 
    topic*: string

  MessagePush* = object
    messages*: seq[WakuMessage]

  Subscriber = object
    connection: Connection
    filter: FilterRequest # @TODO MAKE THIS A SEQUENCE AGAIN?

  WakuFilter* = ref object of LPProtocol
    subscribers*: seq[Subscriber]

proc encode*(filter: ContentFilter): ProtoBuffer =
  result = initProtoBuffer()

  for topic in filter.topics:
    result.write(1, topic)

proc encode*(rpc: FilterRequest): ProtoBuffer =
  result = initProtoBuffer()

  for filter in rpc.contentFilter:
    result.write(1, filter.encode())

  result.write(2, rpc.topic)

proc init*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]
  discard ? pb.getRepeatedField(1, topics)

  ok(ContentFilter(topics: topics))

proc init*(T: type FilterRequest, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRequest(contentFilter: @[], topic: "")
  let pb = initProtoBuffer(buffer)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, buffs)
  
  for buf in buffs:
    rpc.contentFilter.add(? ContentFilter.init(buf))

  discard ? pb.getField(2, rpc.topic)

  ok(rpc)

proc encode*(push: MessagePush): ProtoBuffer =
  result = initProtoBuffer()

  for push in push.messages:
    result.write(1, push.encode())

proc init*(T: type MessagePush, buffer: seq[byte]): ProtoResult[T] =
  var push = MessagePush()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, messages)

  for buf in messages:
    push.messages.add(? WakuMessage.init(buf))

  ok(push)

proc init*(T: type WakuFilter): T =
  var ws = WakuFilter(subscribers: newSeq[Subscriber](0))

  # From my understanding we need to set up filters,
  # then on every message received we need the handle function to send it to the connection
  # if the peer subscribed.
  
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = FilterRequest.init(message)
    if res.isErr:
      return

    ws.subscribers.add(Subscriber(connection: conn, filter: res.value))
    # @TODO THIS IS A VERY ROUGH EXPERIMENT

  ws.handler = handle
  ws.codec = WakuFilterCodec
  result = ws

proc subscription*(proto: WakuFilter): MessageNotificationSubscription =
  ## Returns a Filter for the specific protocol
  ## This filter can then be used to send messages to subscribers that match conditions.   
  proc handle(topic: string, msg: WakuMessage) =
    for subscriber in proto.subscribers:
      if subscriber.filter.topic != topic:
        continue

      for filter in subscriber.filter.contentFilter:
        if msg.contentTopic in filter.topics:
          discard subscriber.connection.writeLp(MessagePush(messages: @[msg]).encode().buffer)
          break

  MessageNotificationSubscription.init(@[], handle)
