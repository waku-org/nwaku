{.push raises: [].}

import chronicles, json_serialization, presto/[route, client]
import
  rest/kernel_api/health/types,
  rest/serdes,
  rest/rest_serdes,
  logos_delivery/kernel/[health_monitor/protocol_health, health_monitor/health_report]

logScope:
  topics = "waku node rest health_api"

proc healthCheck*(): RestResponse[HealthReport] {.
  rest, endpoint: "/health", meth: HttpMethod.MethodGet
.}
