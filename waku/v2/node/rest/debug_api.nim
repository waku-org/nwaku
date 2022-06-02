{.push raises: [Defect].}

import
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client]
import "."/[serdes, utils],
  ../wakunode2

logScope: topics = "rest_api_debug"


#### Types

type
  DebugWakuInfo* = object
    listenAddresses*: seq[string]
    enrUri*: Option[string]


#### Serialization and deserialization

proc writeValue*(writer: var JsonWriter[RestJson], value: DebugWakuInfo)
  {.raises: [IOError, Defect].} =
  writer.beginRecord()
  writer.writeField("listenAddresses", value.listenAddresses)
  if value.enrUri.isSome:
    writer.writeField("enrUri", value.enrUri)
  writer.endRecord()

proc readValue*(reader: var JsonReader[RestJson], value: var DebugWakuInfo)
  {.raises: [SerializationError, IOError, Defect].} =
  var
    listenAddresses: Option[seq[string]]
    enrUri: Option[string]

  for fieldName in readObjectFields(reader):
    case fieldName
    of "listenAddresses":
      if listenAddresses.isSome():
        reader.raiseUnexpectedField("Multiple `listenAddresses` fields found", "DebugWakuInfo")
      listenAddresses = some(reader.readValue(seq[string]))
    of "enrUri":
      if enrUri.isSome():
        reader.raiseUnexpectedField("Multiple `enrUri` fields found", "DebugWakuInfo")
      enrUri = some(reader.readValue(string))
    else:
      unrecognizedFieldWarning()

  if listenAddresses.isNone():
    reader.raiseUnexpectedValue("Field `listenAddresses` is missing")

  value = DebugWakuInfo(
    listenAddresses: listenAddresses.get,
    enrUri: enrUri
  )


####  Server request handlers

proc toDebugWakuInfo(nodeInfo: WakuInfo): DebugWakuInfo = 
    DebugWakuInfo(
      listenAddresses: nodeInfo.listenAddresses,
      enrUri: some(nodeInfo.enrUri)
    )

const ROUTE_DEBUG_INFOV1* = "/debug/v1/info"

proc installDebugInfoV1Handler(router: var RestRouter, node: WakuNode) =
  router.api(MethodGet, ROUTE_DEBUG_INFOV1) do () -> RestApiResponse:
    let info = node.info().toDebugWakuInfo()
    let resp = RestApiResponse.jsonResponse(info, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error()
      return RestApiResponse.internalServerError()

    return resp.get()

proc installDebugApiHandlers*(router: var RestRouter, node: WakuNode) =
  installDebugInfoV1Handler(router, node)


#### Client

proc decodeBytes*(t: typedesc[DebugWakuInfo], data: openArray[byte], contentType: string): RestResult[DebugWakuInfo] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported respose contentType value", contentType = contentType
    return err("Unsupported response contentType")
  
  let decoded = ?decodeFromJsonBytes(DebugWakuInfo, data)
  return ok(decoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc debugInfoV1*(): DebugWakuInfo {.rest, endpoint: "/debug/v1/info", meth: HttpMethod.MethodGet.}