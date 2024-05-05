when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

declarePublicGauge waku_lightpush_errors,
  "number of lightpush protocol errors", ["type"]
declarePublicGauge waku_lightpush_messages,
  "number of lightpush messages received", ["type"]

# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyRequestBodyFailure* = "empty_request_body_failure"
  emptyResponseBodyFailure* = "empty_response_body_failure"
  messagePushFailure* = "message_push_failure"
  requestLimitReachedFailure* = "request_limit_reached_failure"
  messageValidationFailure* = "message_validation_failure"
