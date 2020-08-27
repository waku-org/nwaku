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
  WakuStoreCodec* = "/vac/waku/store/2.0.0-alpha2"

type
  StoreRPC* = object
    query*: seq[HistoryQuery]
    response*: seq[HistoryResponse]

  HistoryQuery* = object
    requestID*: uint64
    topics*: seq[string]

  HistoryResponse* = object
    requestID*: uint64
    messages*: seq[Message]

  WakuStore* = ref object of LPProtocol
    messages*: seq[Message]

method init*(T: type HistoryQuery, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]

  discard ? pb.getField(1, msg.requestID)
  discard ? pb.getRepeatedField(2, topics)

  msg.topics = topics
  ok(msg)

proc init*(T: type HistoryResponse, buffer: seq[byte]): ProtoResult[T] =
  var msg = HistoryResponse()
  let pb = initProtoBuffer(buffer)

  var messages: seq[seq[byte]]

  discard ? pb.getField(1, msg.requestID)
  discard ? pb.getRepeatedField(2, messages)

  for buf in messages:
    msg.messages.add(? protobuf.decodeMessage(initProtoBuffer(buf)))

  ok(msg)

proc init*(T: type StoreRPC, buffer: seq[byte]): ProtoResult[T] =
  var rpc = StoreRPC()
  let pb = initProtoBuffer(buffer)

  var queries: seq[seq[byte]]
  discard ? pb.getRepeatedField(1, queries)

  for buffer in queries:
    rpc.query.add(? HistoryQuery.init(buffer))

  var responses: seq[seq[byte]]
  discard ? pb.getRepeatedField(2, responses)

  for buffer in responses:
    rpc.response.add(? HistoryResponse.init(buffer))

  ok(rpc)

method encode*(query: HistoryQuery): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, query.requestID)

  for topic in query.topics:
    result.write(2, topic)

method encode*(response: HistoryResponse): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, response.requestID)

  for msg in response.messages:
    result.write(2, msg.encodeMessage())

method encode*(response: StoreRPC): ProtoBuffer =
  result = initProtoBuffer()

  for query in response.query:
    result.write(1, query.encode().buffer)

  for response in response.response:
    result.write(2, response.encode().buffer)

proc query(w: WakuStore, query: HistoryQuery): HistoryResponse =
  result = HistoryResponse(requestID: query.requestID, messages: newSeq[Message]())
  for msg in w.messages:
    for topic in query.topics:
      if topic in msg.topicIDs:
        result.messages.insert(msg)
        break

method init*(T: type WakuStore): T =
  var ws = WakuStore()
  
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = await conn.readLp(64*1024)
    var rpc = StoreRPC.init(message)
    if rpc.isErr:
      return

    info "received query"

    var response = StoreRPC(query: newSeq[HistoryQuery](0), response: newSeq[HistoryResponse](0))

    for query in rpc.value.query:
      let res = ws.query(query)
      response.response.add(res)

    await conn.writeLp(response.encode().buffer)

  ws.handler = handle
  ws.codec = WakuStoreCodec
  result = ws

proc filter*(proto: WakuStore): Filter =
  ## The filter function returns the pubsub filter for the node.
  ## This is used to pipe messages into the storage, therefore
  ## the filter should be used by the component that receives
  ## new messages.
  proc handle(msg: Message) =
    proto.messages.add(msg)

  Filter.init(@[], handle)
