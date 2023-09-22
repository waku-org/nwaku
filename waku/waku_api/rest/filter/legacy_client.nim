when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sets,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import
  ../../../waku_core,
  ../serdes,
  ../responses,
  ./types

export types

logScope:
  topics = "waku node rest client v1"

proc encodeBytes*(value: FilterLegacySubscribeRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc decodeBytes*(t: typedesc[string], value: openarray[byte],
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
proc filterPostSubscriptionsV1*(body: FilterLegacySubscribeRequest): 
        RestResponse[string] 
        {.rest, endpoint: "/filter/v1/subscriptions", meth: HttpMethod.MethodPost.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc filterDeleteSubscriptionsV1*(body: FilterLegacySubscribeRequest): 
        RestResponse[string] 
        {.rest, endpoint: "/filter/v1/subscriptions", meth: HttpMethod.MethodDelete.}

proc decodeBytes*(t: typedesc[FilterGetMessagesResponse], 
                  data: openArray[byte], 
                  contentType: Opt[ContentTypeData]): RestResult[FilterGetMessagesResponse] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported response contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = ?decodeFromJsonBytes(FilterGetMessagesResponse, data)
  return ok(decoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc filterGetMessagesV1*(contentTopic: string): 
        RestResponse[FilterGetMessagesResponse] 
        {.rest, endpoint: "/filter/v1/messages/{contentTopic}", meth: HttpMethod.MethodGet.}
