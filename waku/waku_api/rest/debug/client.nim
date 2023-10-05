when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client]
import
  ../serdes,
  ../responses,
  ./types

export types


logScope:
  topics = "waku node rest debug_api"


proc decodeBytes*(t: typedesc[DebugWakuInfo], data: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[DebugWakuInfo] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported respose contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = ?decodeFromJsonBytes(DebugWakuInfo, data)
  return ok(decoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugInfoV1*(): RestResponse[DebugWakuInfo] {.rest, endpoint: "/debug/v1/info", meth: HttpMethod.MethodGet.}


proc decodeBytes*(t: typedesc[string], value: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[string] =
  if MediaType.init($contentType) != MIMETYPE_TEXT:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
  return ok(res)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugVersionV1*(): RestResponse[string] {.rest, endpoint: "/debug/v1/version", meth: HttpMethod.MethodGet.}
