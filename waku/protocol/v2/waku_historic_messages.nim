import libp2p/protocols/protocol

const
  HistoricMessagesCodec = "/waku/history/1.0.0"

type
  HistoricMessages* = ref object of LPProtocol

method init*(p: HistoricMessages) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    discard

  p.handle = handle
  p.codec = HistoricMessagesCodec
