{.push raises: [].}

import chronicles, json_serialization, presto/route
import ../../../waku_node, ../responses, ../serdes, ./types

export types

logScope:
  topics = "waku node rest debug_api"

const ROUTE_DEBUG_INFOV1* = "/debug/v1/info"

proc installDebugInfoV1Handler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_DEBUG_INFOV1) do() -> RestApiResponse:
    let info = node.info().toDebugWakuInfo()
    let resp = RestApiResponse.jsonResponse(info, status = Http200)
    if resp.isErr():
      debug "An error occurred while building the json respose", error = resp.error
      return RestApiResponse.internalServerError()

    return resp.get()

const ROUTE_DEBUG_VERSIONV1* = "/debug/v1/version"

proc installDebugVersionV1Handler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_DEBUG_VERSIONV1) do() -> RestApiResponse:
    return RestApiResponse.textResponse(git_version, status = Http200)

proc installDebugApiHandlers*(router: var RestRouter, node: WakuNode) =
  installDebugInfoV1Handler(router, node)
  installDebugVersionV1Handler(router, node)
