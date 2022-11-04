when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics


declarePublicGauge waku_filter_subscribers, "number of light node filter subscribers"
declarePublicGauge waku_filter_errors, "number of filter protocol errors", ["type"]
declarePublicGauge waku_filter_messages, "number of filter messages received", ["type"]
declarePublicGauge waku_node_filters, "number of content filter subscriptions"


# Error types (metric label values)
const
  dialFailure* = "dial_failure"
  decodeRpcFailure* = "decode_rpc_failure"
  peerNotFoundFailure* = "peer_not_found_failure"
  emptyMessagePushFailure* = "empty_message_push_failure"
  emptyFilterRequestFailure* = "empty_filter_request_failure"

