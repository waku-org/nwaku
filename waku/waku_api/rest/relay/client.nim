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
  topics = "waku node rest client"


proc encodeBytes*(value: seq[PubSubTopic],
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
proc relayPostSubscriptionsV1*(body: seq[PubsubTopic]): RestResponse[string] {.rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodPost.}
proc relayPostAutoSubscriptionsV1*(body: seq[ContentTopic]): RestResponse[string] {.rest, endpoint: "/relay/v1/auto/subscriptions", meth: HttpMethod.MethodPost.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayDeleteSubscriptionsV1*(body: seq[PubsubTopic]): RestResponse[string] {.rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodDelete.}
proc relayDeleteAutoSubscriptionsV1*(body: seq[ContentTopic]): RestResponse[string] {.rest, endpoint: "/relay/v1/auto/subscriptions", meth: HttpMethod.MethodDelete.}

proc decodeBytes*(t: typedesc[RelayGetMessagesResponse], data: openArray[byte], contentType: Opt[ContentTypeData]): RestResult[RelayGetMessagesResponse] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported respose contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = ?decodeFromJsonBytes(RelayGetMessagesResponse, data)
  return ok(decoded)

proc encodeBytes*(value: RelayPostMessagesRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayGetMessagesV1*(pubsubTopic: string): RestResponse[RelayGetMessagesResponse] {.rest, endpoint: "/relay/v1/messages/{pubsubTopic}", meth: HttpMethod.MethodGet.}
proc relayGetAutoMessagesV1*(contentTopic: string): RestResponse[RelayGetMessagesResponse] {.rest, endpoint: "/relay/v1/auto/messages/{contentTopic}", meth: HttpMethod.MethodGet.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayPostMessagesV1*(pubsubTopic: string, body: RelayPostMessagesRequest): RestResponse[string] {.rest, endpoint: "/relay/v1/messages/{pubsubTopic}", meth: HttpMethod.MethodPost.}
proc relayPostAutoMessagesV1*(body: RelayPostMessagesRequest): RestResponse[string] {.rest, endpoint: "/relay/v1/auto/messages", meth: HttpMethod.MethodPost.}
