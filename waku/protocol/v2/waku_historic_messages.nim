import 
  libp2p/protocols/protocol,
  protobuf_serialization

const
  HistoricMessagesCodec = "/waku/history/1.0.0"

type
  Cursor* = ref object
    before* {.fieldNumber: 1.}: seq[byte]
    after* {.fieldNumber: 2.}: seq[byte]

  Query* = ref object
    from* {.fieldNumber: 1.}: int32
    to* {.fieldNumber: 2.}: int32
    bloom* {.fieldNumber: 3.}: seq[byte]
    limit* {.fieldNumber: 4.}: int32
    topics* {.fieldNumber: 5.}: seq[seq[byte]]
    cursor* {.fieldNumber: 6.}: Cursor

  HistoricMessages* = ref object of LPProtocol

method init*(p: HistoricMessages) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    discard

  p.handle = handle
  p.codec = HistoricMessagesCodec
