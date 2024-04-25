when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles, json_serialization, json_serialization/std/options, presto/[route, client]
import ../../../waku_store_legacy/common, ../serdes, ../responses, ./types

export types

logScope:
  topics = "waku node rest legacy store_api"

proc decodeBytes*(
    t: typedesc[StoreResponseRest],
    data: openArray[byte],
    contentType: Opt[ContentTypeData],
): RestResult[StoreResponseRest] =
  if MediaType.init($contentType) == MIMETYPE_JSON:
    let decoded = ?decodeFromJsonBytes(StoreResponseRest, data)
    return ok(decoded)

  if MediaType.init($contentType) == MIMETYPE_TEXT:
    var res: string
    if len(data) > 0:
      res = newString(len(data))
      copyMem(addr res[0], unsafeAddr data[0], len(data))

    return ok(
      StoreResponseRest(
        messages: newSeq[StoreWakuMessage](0),
        cursor: none(HistoryCursorRest),
        # field that contain error information
        errorMessage: some(res),
      )
    )

  # If everything goes wrong
  return err(cstring("Unsupported contentType " & $contentType))

proc getStoreMessagesV1*(
  # URL-encoded reference to the store-node
  peerAddr: string = "",
  pubsubTopic: string = "",
  # URL-encoded comma-separated list of content topics
  contentTopics: string = "",
  startTime: string = "",
  endTime: string = "",

  # Optional cursor fields
  senderTime: string = "",
  storeTime: string = "",
  digest: string = "", # base64-encoded digest
  pageSize: string = "",
  ascending: string = "",
): RestResponse[StoreResponseRest] {.
  rest, endpoint: "/store/v1/messages", meth: HttpMethod.MethodGet
.}

proc getStoreMessagesV1*(
  # URL-encoded reference to the store-node
  peerAddr: Option[string],
  pubsubTopic: string = "",
  # URL-encoded comma-separated list of content topics
  contentTopics: string = "",
  startTime: string = "",
  endTime: string = "",

  # Optional cursor fields
  senderTime: string = "",
  storeTime: string = "",
  digest: string = "", # base64-encoded digest
  pageSize: string = "",
  ascending: string = "",
): RestResponse[StoreResponseRest] {.
  rest, endpoint: "/store/v1/messages", meth: HttpMethod.MethodGet
.}
