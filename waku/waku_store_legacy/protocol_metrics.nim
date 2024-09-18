{.push raises: [].}

import metrics

declarePublicGauge waku_legacy_store_errors,
  "number of legacy store protocol errors", ["type"]
declarePublicGauge waku_legacy_store_queries, "number of legacy store queries received"

## f.e., we have the "query" phase, where the node performs the query to the database,
## and the "libp2p" phase, where the node writes the store response to the libp2p stream.
declarePublicGauge waku_legacy_store_time_seconds,
  "Time in seconds spent by each store phase", labels = ["phase"]

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyRpcQueryFailure* = "empty_rpc_query_failure"
  emptyRpcResponseFailure* = "empty_rpc_response_failure"
