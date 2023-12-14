when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  presto/route
import
  ../../../waku_node,
  ../responses,
  ../serdes

logScope:
  topics = "waku node rest health_api"

const ROUTE_HEALTH* = "/health"

const FutIsReadyTimout = 5.seconds

proc installHealthApiHandler*(router: var RestRouter, node: WakuNode) =
  ## /health endpoint provides information about node readiness to caller.
  ## Currently it is restricted to checking RLN (if mounted) proper setup
  ## TODO: Leter to extend it to a broader information about each subsystem state
  ## report. Rest response to change to JSON structure that can hold exact detailed 
  ## information.
  
  router.api(MethodGet, ROUTE_HEALTH) do () -> RestApiResponse:

    let isReadyStateFut = node.isReady()
    if not await isReadyStateFut.withTimeout(FutIsReadyTimout):
       return RestApiResponse.internalServerError("Health check timed out")

    var msg = "Node is healthy"
    var status = Http200

    try:
      if not isReadyStateFut.read():
        msg = "Node is not ready"
        status = Http503
    except:
      msg = "exception reading state: " & getCurrentExceptionMsg()
      status = Http500

    return RestApiResponse.textResponse(msg, status)
