{.push raises: [].}

import metrics

export metrics

declarePublicGauge waku_filter_errors, "number of filter protocol errors", ["type"]
declarePublicGauge waku_filter_requests,
  "number of filter subscribe requests received", ["type"]
declarePublicGauge waku_filter_subscriptions, "number of subscribed filter clients"
declarePublicHistogram waku_filter_request_duration_seconds,
  "duration of filter subscribe requests", ["type"]
declarePublicHistogram waku_filter_handle_message_duration_seconds,
  "duration to push message to filter subscribers"

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  requestIdMismatch* = "request_id_mismatch"
  errorResponse* = "error_response"
  pushTimeoutFailure* = "push_timeout_failure"
