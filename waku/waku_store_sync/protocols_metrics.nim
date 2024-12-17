import metrics

declarePublicHistogram reconciliation_roundtrips,
  "the nubmer of roundtrips for each reconciliation",
  buckets = [0.0, 1.0, 2.0, 3.0, 5.0, 10.0]

declarePublicSummary total_bytes_exchanged,
  "the number of bytes sent and received by the protocols",
  ["transfer_sent", "transfer_recv", "reconciliation_sent", "reconciliation_recv"]

declarePublicCounter total_messages_exchanged,
  "the number of messages sent and received by the transfer protocol", ["sent", "recv"]
