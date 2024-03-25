when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

declarePublicCounter waku_service_requests,
  "number of non-relay service requests received", ["service"]
declarePublicCounter waku_service_requests_rejected,
  "number of non-relay service requests received being rejected due to limit overdue",
  ["service"]
