import
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/pubsub/rpc/messages
  
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

method init*(T: type StoreRPC): T =
  discard

method encode*(response: StoreRPC): seq[byte] =
  discard

method init*(T: type HistoryQuery): T =
  discard

method encode*(response: HistoryResponse): seq[byte] =
  discard

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
