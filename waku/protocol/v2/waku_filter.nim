import
  std/tables,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/pubsub/pubsubpeer,
  libp2p/protocols/pubsub/floodsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/[messages, protobuf],
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ./message_notifier

# NOTE This is just a start, the design of this protocol isn't done yet. It
# should be direct payload exchange (a la req-resp), not be coupled with the
# relay protocol.

const
  WakuFilterCodec* = "/vac/waku/filter/2.0.0-alpha2"

type
  ContentFilter* = object
    topics*: seq[string]

  FilterRPC* = object
    filters*: seq[ContentFilter]

  Subscriber = object
    connection: Connection
    filter: FilterRPC

  WakuFilter* = ref object of LPProtocol
    subscribers*: seq[Subscriber]

proc encode*(filter: ContentFilter): ProtoBuffer =
  result = initProtoBuffer()

  for topic in filter.topics:
    result.write(1, topic)

proc encode*(rpc: FilterRPC): ProtoBuffer =
  result = initProtoBuffer()

  for filter in rpc.filters:
    result.write(1, filter.encode())

proc init*(T: type ContentFilter, buffer: seq[byte]): ProtoResult[T] =
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]
  discard ? pb.getRepeatedField(1, topics)

  ok(ContentFilter(topics: topics))

proc init*(T: type FilterRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = FilterRPC(filters: @[])
  let pb = initProtoBuffer(buffer)

  var buffs: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, buffs)
  
  for buf in buffs:
    rpc.filters.add(? ContentFilter.init(buf))

  ok(rpc)

proc init*(T: type WakuFilter): T =
  var ws = WakuFilter(subscribers: newSeq[Subscriber](0))

  # From my understanding we need to set up filters,
  # then on every message received we need the handle function to send it to the connection
  # if the peer subscribed.
  
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var res = FilterRPC.init(message)
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
  proc handle(msg: Message) =
    for subscriber in proto.subscribers:
      for f in subscriber.filter.filters:
        for topic in f.topics:
          if topic in msg.topicIDs:
            discard subscriber.connection.writeLp(msg.encodeMessage())
            break

  MessageNotificationSubscription.init(@[], handle)
