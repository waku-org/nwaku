when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

export metrics

declarePublicGauge waku_filter_errors, "number of filter protocol errors", ["type"]
declarePublicGauge waku_filter_requests, "number of filter subscribe requests received", ["type"]

# Error types (metric label values)
const
  decodeRpcFailure* = "decode_rpc_failure"
