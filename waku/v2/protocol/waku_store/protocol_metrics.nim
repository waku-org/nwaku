{.push raises: [Defect].}

import metrics


declarePublicGauge waku_store_messages, "number of historical messages", ["type"]
declarePublicGauge waku_store_errors, "number of store protocol errors", ["type"]
declarePublicGauge waku_store_queries, "number of store queries received"
declarePublicHistogram waku_store_insert_duration_seconds, "message insertion duration"
declarePublicHistogram waku_store_query_duration_seconds, "history query duration"


# Error types (metric label values)
const
  invalidMessage* = "invalid_message"
  insertFailure* = "insert_failure"
  retPolicyFailure* = "retpolicy_failure"
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"