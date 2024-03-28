when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

declarePublicGauge waku_legacy_store_errors,
  "number of legacy store protocol errors", ["type"]
declarePublicGauge waku_legacy_store_queries, "number of legacy store queries received"

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyRpcQueryFailure* = "empty_rpc_query_failure"
  emptyRpcResponseFailure* = "empty_rpc_response_failure"
