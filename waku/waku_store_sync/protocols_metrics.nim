import metrics

type ProtoDirection* {.pure.} = enum
  ReconRecv = "reconciliation_recv"
  ReconSend = "reconciliation_sent"
  TransfRecv = "transfer_recv"
  TransfSend = "transfer_sent"

declarePublicHistogram reconciliation_roundtrips,
  "the nubmer of roundtrips for each reconciliation",
  buckets = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, Inf]

declarePublicSummary total_bytes_exchanged,
  "the number of bytes sent and received by the protocols",
  ["transfer_sent", "transfer_recv", "reconciliation_sent", "reconciliation_recv"]

declarePublicCounter total_transfer_messages_exchanged,
  "the number of messages sent and received by the transfer protocol",
  ["transfer_sent", "transfer_recv"]
