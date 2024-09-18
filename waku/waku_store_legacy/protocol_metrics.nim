{.push raises: [].}

import metrics

declarePublicGauge waku_legacy_store_errors,
  "number of legacy store protocol errors", ["type"]
declarePublicGauge waku_legacy_store_queries, "number of legacy store queries received"

## "query-db-time" phase considers the time when node performs the query to the database.
## "send-store-resp-time" phase is the time when node writes the store response to the store-client.
declarePublicGauge waku_legacy_store_time_seconds,
  "Time in seconds spent by each store phase", labels = ["phase"]

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyRpcQueryFailure* = "empty_rpc_query_failure"
  emptyRpcResponseFailure* = "empty_rpc_response_failure"
