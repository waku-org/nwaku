when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronicles, json_serialization, presto/route
import ../../../waku_node, ../responses, ../serdes

logScope:
  topics = "waku node rest health_api"

const ROUTE_HEALTH* = "/health"

const FitHealthReportTimeout = 5.seconds

proc installHealthApiHandler*(
    router: var RestRouter, nodeHealthMonitor: WakuNodeHealthMonitor
) =
  router.api(MethodGet, ROUTE_HEALTH) do() -> RestApiResponse:
    let healthReportFut = nodeHealthMonitor.getNodeHealthReport()
    if not await healthReportFut.withTimeout(FitHealthReportTimeout):
      return RestApiResponse.internalServerError("Health check timed out")

    var msg = ""
    var status = Http200

    try:
      if healthReportFut.completed():
        let healthReport = healthReportFut.read()
        msg = $healthReport
      else:
        msg = "Health check failed"
        status = Http503
    except:
      msg = "exception reading state: " & getCurrentExceptionMsg()
      status = Http500

    return RestApiResponse.textResponse(msg, status)
