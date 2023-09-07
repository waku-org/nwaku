when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  presto/route
import
  ../../waku_node,
  ../responses,
  ../serdes

logScope:
  topics = "waku node rest health_api"

const ROUTE_HEALTH* = "/health"

const futIsReadyTimout = 5.seconds

proc installHealthApiHandler*(router: var RestRouter, node: WakuNode) =

  router.api(MethodGet, ROUTE_HEALTH) do () -> RestApiResponse:

    let isReadyStateFut = node.isReady()
    if not await isReadyStateFut.withTimeout(futIsReadyTimout):
       return RestApiResponse.internalServerError("Health check timed out")   

    var msg = "Node is healthy"
    var status = Http200

    if not isReadyStateFut.read(): 
      msg = "Node is not ready"
      status = Http503

    return RestApiResponse.textResponse(msg, status)
