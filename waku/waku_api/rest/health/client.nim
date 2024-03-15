when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles, json_serialization, json_serialization/std/options, presto/[route, client]
import ../serdes, ../responses, ../rest_serdes

logScope:
  topics = "waku node rest health_api"

proc healthCheck*(): RestResponse[string] {.
  rest, endpoint: "/health", meth: HttpMethod.MethodGet
.}
