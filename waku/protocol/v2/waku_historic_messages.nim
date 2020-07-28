import 
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  stew/results

import ./filter

const
  HistoricMessagesCodec = "/waku/history/1.0.0"

type

  HistoryQuery* = object

  HistoryResponse* = object
    messages: seq[Message]

  HistoricMessages* = ref object of LPProtocol
    messages: seq[Message]

method init*(T: type HistoricMessages) = T
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    # @TODO PROBABLY NOT HERE
    var message = conn.readLp(64*1024)
    let query = HistoryQuery() # @TODO

    

    info "received query"

    # @TODO QUERY AND THEN RESPOND

  result.messages = newSeq[Message]()
  result.handle = handle
  result.codec = HistoricMessagesCodec

proc filter*(proto: HistoricMessages): Filter =
  proc handle(msg: Message) =
    discard

  Filter.init(@[], handle)
