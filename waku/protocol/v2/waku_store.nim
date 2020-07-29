import
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/protocols/pubsub/rpc/messages
  
import stew/results
import ./filter

const
  WakuStoreCodec = "/vac/waku/store/2.0.0-alpha2"

type
  HistoryQuery* = object
    topics*: seq[string]

  HistoryResponse* = object
    messages*: seq[Message]

  WakuStore* = ref object of LPProtocol
    messages*: seq[Message]

method init*(T: type HistoryQuery): T =
  discard

method encode*(response: HistoryResponse): seq[byte] =
  discard

method init*(T: type WakuStore) = T
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var message = conn.readLp(64*1024)
    var query = HistoryQuery.init(message)
    if query.isError():
      return

    info "received query"

    var returns = HistoryResponse(messages: newSeq[Message]())
    
    for msg in result.messages:
      block topicLoop:
        for topic in query.topics:
          if topic in msg.topics:
            returns.insert(msg)
            break topicLoop

    conn.writeLp(returns)

  result.handle = handle
  result.codec = WakuStoreCodec

proc filter*(proto: WakuStore): Filter =
  proc handle(msg: Message) =
    proto.insert(msg)

  Filter.init(@[], handle)