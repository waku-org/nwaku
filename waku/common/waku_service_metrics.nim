when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

declarePublicCounter waku_service_requests,
  "number of non-relay service requests received", ["service", "state"]

declarePublicCounter waku_service_network_bytes,
  "total incoming traffic of specific waku services", labels = ["service", "direction"]
