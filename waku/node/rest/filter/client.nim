when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  json,
  std/sets,
  stew/byteutils,
  strformat,
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
  topics = "waku node rest client v2"

proc encodeBytes*(value: FilterSubscribeRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc encodeBytes*(value: FilterSubscriberPing,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc encodeBytes*(value: FilterUnsubscribeRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc encodeBytes*(value: FilterUnsubscribeAllRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc decodeBytes*(t: typedesc[FilterSubscriptionResponse],
                  value: openarray[byte],
                  contentType: Opt[ContentTypeData]):

                RestResult[FilterSubscriptionResponse] =

  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")

  let decoded = ?decodeFromJsonBytes(FilterSubscriptionResponse, value)
  return ok(decoded)

proc filterSubscriberPing*(requestId: string):
        RestResponse[FilterSubscriptionResponse]
        {.rest, endpoint: "/filter/v2/subscriptions/{requestId}", meth: HttpMethod.MethodGet.}

proc filterPostSubscriptions*(body: FilterSubscribeRequest):
        RestResponse[FilterSubscriptionResponse]
        {.rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodPost.}

proc filterPutSubscriptions*(body: FilterSubscribeRequest):
        RestResponse[FilterSubscriptionResponse]
        {.rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodPut.}

proc filterDeleteSubscriptions*(body: FilterUnsubscribeRequest):
        RestResponse[FilterSubscriptionResponse]
        {.rest, endpoint: "/filter/v2/subscriptions", meth: HttpMethod.MethodDelete.}

proc filterDeleteAllSubscriptions*(body: FilterUnsubscribeAllRequest):
        RestResponse[FilterSubscriptionResponse]
        {.rest, endpoint: "/filter/v2/subscriptions/all", meth: HttpMethod.MethodDelete.}

proc decodeBytes*(t: typedesc[FilterGetMessagesResponse],
                  data: openArray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[FilterGetMessagesResponse] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported response contentType value", contentType = contentType
    return err("Unsupported response contentType")

  let decoded = ?decodeFromJsonBytes(FilterGetMessagesResponse, data)
  return ok(decoded)

proc filterGetMessagesV1*(contentTopic: string):
        RestResponse[FilterGetMessagesResponse]
        {.rest, endpoint: "/filter/v2/messages/{contentTopic}", meth: HttpMethod.MethodGet.}
