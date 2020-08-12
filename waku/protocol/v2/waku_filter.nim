import chronos, chronicles
import ./filter
import tables
import libp2p/protocols/pubsub/pubsub,
       libp2p/protocols/pubsub/pubsubpeer,
       libp2p/protocols/pubsub/floodsub,
       libp2p/protocols/pubsub/gossipsub,
       libp2p/protocols/pubsub/rpc/[messages, protobuf],
       libp2p/protocols/protocol,
       libp2p/protobuf/minprotobuf,
       libp2p/stream/connection

import metrics

import stew/results

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

proc init*(T: type ContentFilter, buffer: seq[byte]): T =
  result = ContentFilter()

  let pb = initProtoBuffer(buffer)

  var topics: seq[string]
  var res = pb.getRepeatedField(1, topics)
  result.topics = topics

proc init*(T: type FilterRPC, buffer: seq[byte]): T =
  result = FilterRPC(filters: @[])
  let pb = initProtoBuffer(buffer)

  var buffs: seq[seq[byte]]
  var res = pb.getRepeatedField(1, buffs)
  for buf in buffs:
    result.filters.add(ContentFilter.init(buf))

method init*(T: type WakuStore): T =
  var ws = WakuFilter(subscribers: newSeq[Subscriber](0))

  # From my understanding we need to set up filters,
  # then on every message received we need the handle function to send it to the connection
  # if the peer subscribed.
  
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var rpc = FilterRPC.init(message)

    ws.subscribers.add(Subscriber(connection: conn, filter: rpc))
    # @TODO THIS IS A VERY ROUGH EXPERIMENT

  ws.handler = handle
  ws.codec = WakuFilterCodec
  result = ws

proc filter*(proto: WakuFilter): Filter =
  proc handle(msg: Message) =
    for subscriber in proto.subscribers:
      for f in subscriber.filter.filters:
        for topic in f.topics:
          if f.topic in msg.topicIDs:
            subscriber.connection.writeLp(msg.encode().buffer)
            break

  Filter.init(@[], handle)