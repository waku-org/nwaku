{.push raises: [].}

import chronicles, json_serialization, presto/[route, client]
import
  logos_delivery/kernel/[common/health/protocol_health, common/health/health_report],
  rest/kernel_api/health/types,
  rest/serdes,
  rest/rest_serdes
logScope:
  topics = "waku node rest health_api"

proc healthCheck*(): RestResponse[HealthReport] {.
  rest, endpoint: "/health", meth: HttpMethod.MethodGet
.}
