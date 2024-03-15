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
import ../../../waku_core, ../serdes, ../responses, ../rest_serdes, ./types

export types

logScope:
  topics = "waku node rest client v1"

proc encodeBytes*(
    value: FilterLegacySubscribeRequest, contentType: string
): RestResult[seq[byte]] =
  return encodeBytesOf(value, contentType)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc filterPostSubscriptionsV1*(
  body: FilterLegacySubscribeRequest
): RestResponse[string] {.
  rest, endpoint: "/filter/v1/subscriptions", meth: HttpMethod.MethodPost
.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc filterDeleteSubscriptionsV1*(
  body: FilterLegacySubscribeRequest
): RestResponse[string] {.
  rest, endpoint: "/filter/v1/subscriptions", meth: HttpMethod.MethodDelete
.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc filterGetMessagesV1*(
  contentTopic: string
): RestResponse[FilterGetMessagesResponse] {.
  rest, endpoint: "/filter/v1/messages/{contentTopic}", meth: HttpMethod.MethodGet
.}
