import
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/pubsub/rpc/[messages, protobuf]
  
import stew/results
import ./filter

const
  WakuStoreCodec = "/vac/waku/store/2.0.0-alpha2"

type
  StoreRPC* = object
    query*: seq[HistoryQuery]
    response*: seq[HistoryResponse] 

  HistoryQuery* = object
    topics*: seq[string]

  HistoryResponse* = object
    messages*: seq[Message]

  WakuStore* = ref object of LPProtocol
    messages*: seq[Message]

method init*(T: type StoreRPC, buffer: seq[byte]): T =
  result = StoreRPC()
  let pb = initProtoBuffer(buffer)
  
  var queries: seq[seq[byte]]
  let res = pb.getRepeatedField(1, queries)

  for buffer in queries:
    result.query.add(HistoryQuery.init(buffer))

  var responses: seq[seq[byte]]
  let res = pb.getRepeatedField(2, responses)

  for buffer in responses:
    result.response.add(HistoryResponse.init(buffer))

method encode*(response: StoreRPC): ProtoBuffer =
  result = initProtoBuffer()

  for query in response.query:
    result.write(1, query.encode().buffer)

  for response in response.response:
    result.write(2, response.encode().buffer)

method init*(T: type HistoryQuery, buffer: seq[byte]): T =
  result = HistoryQuery()
  let pb = initProtoBuffer(buffer)

  var topics: seq[string]
  let res = pb.getRepeatedField(1, topics)

  result.topics = topics

method encode*(query: HistoryQuery): ProtoBuffer =
  result = initProtoBuffer()

  for topic in query.topics:
    result.write(1, topic)

method encode*(response: HistoryResponse): ProtoBuffer =
  result = initProtoBuffer()

  for msg in response.messages:
    result.write(1, msg.encodeMessage())

proc query(w: WakuStore, query: HistoryQuery): HistoryResponse =
  block msgLoop:  
    for msg in result.messages:
        for topic in query.topics:
          if topic in msg.topics:
            result.messages.insert(msg)
            continue msgLoop

method init*(T: type WakuStore) = T
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = conn.readLp(64*1024)
    var rpc = StoreRPC.init(message)
    if rpc.isError():
      return

    info "received query"

    var response = StoreRPC(query: newSeq[HistoryQuery](), response: newSeq[HistoryResponse]())

    for query in rpc.query:
      response.response.insert(result.query(query))

    conn.writeLp(response.encode())

  result.handle = handle
  result.codec = WakuStoreCodec

proc filter*(proto: WakuStore): Filter =
  proc handle(msg: Message) =
    proto.insert(msg)

  Filter.init(@[], handle)
