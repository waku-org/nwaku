import metrics

const
  Reconciliation* = "reconciliation"
  Transfer* = "transfer"
  Receiving* = "receive"
  Sending* = "sent"

declarePublicHistogram reconciliation_roundtrips,
  "the nubmer of roundtrips for each reconciliation",
  buckets = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0, Inf]

declarePublicSummary total_bytes_exchanged,
  "the number of bytes sent and received by the protocols", ["protocol", "direction"]

declarePublicCounter total_transfer_messages_exchanged,
  "the number of messages sent and received by the transfer protocol", ["direction"]
