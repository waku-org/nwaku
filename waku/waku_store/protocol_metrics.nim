{.push raises: [].}

import metrics

declarePublicGauge waku_store_errors, "number of store protocol errors", ["type"]
declarePublicGauge waku_store_queries, "number of store queries received"

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyRpcQueryFailure* = "empty_rpc_query_failure"
  emptyRpcResponseFailure* = "empty_rpc_response_failure"
