{.push raises: [Defect].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client]
import "."/api_types
import ".."/[serdes, utils]
import ../../waku_node

logScope:
  topics = "waku node rest debug_api"


####  Server request handlers

const ROUTE_DEBUG_INFOV1* = "/debug/v1/info"

proc installDebugInfoV1Handler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_DEBUG_INFOV1) do () -> RestApiResponse:
    let info = node.info().toDebugWakuInfo()
    let resp = RestApiResponse.jsonResponse(info, status=Http200)
    if resp.isErr():
      debug "An error occurred while building the json respose", error=resp.error()
      return RestApiResponse.internalServerError()

    return resp.get()

proc installDebugApiHandlers*(router: var RestRouter, node: WakuNode) =
  installDebugInfoV1Handler(router, node)


#### Client

proc decodeBytes*(t: typedesc[DebugWakuInfo], data: openArray[byte], contentType: Opt[ContentTypeData]): RestResult[DebugWakuInfo] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported respose contentType value", contentType = contentType
    return err("Unsupported response contentType")
  
  let decoded = ?decodeFromJsonBytes(DebugWakuInfo, data)
  return ok(decoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugInfoV1*(): RestResponse[DebugWakuInfo] {.rest, endpoint: "/debug/v1/info", meth: HttpMethod.MethodGet.}
