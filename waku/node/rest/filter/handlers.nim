when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/strformat,
  std/sequtils,
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common
import
  ../../../waku_core,
  ../../../waku_filter,
  ../../../waku_filter_v2,
  ../../../waku_filter_v2/client as filter_protocol_client,
  ../../../waku_filter_v2/common as filter_protocol_type,
  ../../message_cache,
  ../../peer_manager,
  ../../waku_node,
  ../serdes,
  ../responses,
  ./types

export types

logScope:
  topics = "waku node rest filter_api_v2"

const futTimeoutForSubscriptionProcessing* = 5.seconds

#### Request handlers

const ROUTE_FILTER_SUBSCRIPTIONS* = "/filter/v2/subscriptions"

const ROUTE_FILTER_ALL_SUBSCRIPTIONS* = "/filter/v2/subscriptions/all"

const filterMessageCacheDefaultCapacity* = 30

type
  MessageCache* = message_cache.MessageCache[ContentTopic]

func decodeRequestBody[T](contentBody: Option[ContentBody]) : Result[T, RestApiResponse] =
  if contentBody.isNone():
    return err(RestApiResponse.badRequest("Missing content body"))

  let reqBodyContentType = MediaType.init($contentBody.get().contentType)
  if reqBodyContentType != MIMETYPE_JSON:
    return err(RestApiResponse.badRequest("Wrong Content-Type, expected application/json"))

  let reqBodyData = contentBody.get().data

  let requestResult = decodeFromJsonBytes(T, reqBodyData)
  if requestResult.isErr():
    return err(RestApiResponse.badRequest("Invalid content body, could not decode. " &
                                          $requestResult.error))

  return ok(requestResult.get())

proc getErrorCause(err: filter_protocol_type.FilterSubscribeError): string =
  ## Retrieve proper error cause of FilterSubscribeError - due stringify make some parts of text double

  case err.kind:
  of FilterSubscribeErrorKind.PEER_DIAL_FAILURE:
    err.address
  of FilterSubscribeErrorKind.BAD_RESPONSE, FilterSubscribeErrorKind.BAD_REQUEST,
     FilterSubscribeErrorKind.NOT_FOUND, FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
    err.cause
  of FilterSubscribeErrorKind.UNKNOWN:
    "UNKNOWN"

proc convertResponse(T: type FilterSubscriptionResponse, requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeResult): T =
  ## Properly convert filter protocol's response to rest response

  if protocolClientRes.isErr():
    return FilterSubscriptionResponse(
              requestId: requestId,
              statusCode: uint32(protocolClientRes.error().kind),
              statusDesc: getErrorCause(protocolClientRes.error())
            )
  else:
    return FilterSubscriptionResponse(
              requestId: requestId,
              statusCode: 0,
              statusDesc: ""
            )

proc convertResponse(T: type FilterSubscriptionResponse, requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeError): T =
  ## Properly convert filter protocol's response to rest response in case of error

  return FilterSubscriptionResponse(
            requestId: requestId,
            statusCode: uint32(protocolClientRes.kind),
            statusDesc: $protocolClientRes
          )

proc convertErrorKindToHttpStatus(kind: filter_protocol_type.FilterSubscribeErrorKind): HttpCode =
  ## Filter protocol's error code is not directly convertible to HttpCodes hence this converter

  case kind:
    of filter_protocol_type.FilterSubscribeErrorKind.UNKNOWN:
      return Http200
    of filter_protocol_type.FilterSubscribeErrorKind.PEER_DIAL_FAILURE:
      return Http504 #gateway timout
    of filter_protocol_type.FilterSubscribeErrorKind.BAD_RESPONSE:
      return Http500 # internal server error
    of filter_protocol_type.FilterSubscribeErrorKind.BAD_REQUEST:
      return Http400
    of filter_protocol_type.FilterSubscribeErrorKind.NOT_FOUND:
      return Http404
    of filter_protocol_type.FilterSubscribeErrorKind.SERVICE_UNAVAILABLE:
      return Http503
    else:
      return Http500

proc makeRestResponse(requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeResult): RestApiResponse =
  let filterSubscriptionResponse = FilterSubscriptionResponse.convertResponse(requestId, protocolClientRes)

  var httpStatus : HttpCode = Http200

  if protocolClientRes.isErr():
    httpStatus = convertErrorKindToHttpStatus(protocolClientRes.error().kind) # TODO: convert status codes!

  let resp = RestApiResponse.jsonResponse(filterSubscriptionResponse, status=httpStatus)

  if resp.isErr():
    error "An error ocurred while building the json respose: ", error=resp.error
    return RestApiResponse.internalServerError(fmt("An error ocurred while building the json respose: {resp.error}"))

  return resp.get()

proc makeRestResponse(requestId: string, protocolClientRes: filter_protocol_type.FilterSubscribeError): RestApiResponse =
  let filterSubscriptionResponse = FilterSubscriptionResponse.convertResponse(requestId, protocolClientRes)

  let httpStatus = convertErrorKindToHttpStatus(protocolClientRes.kind) # TODO: convert status codes!

  let resp = RestApiResponse.jsonResponse(filterSubscriptionResponse, status=httpStatus)

  if resp.isErr():
    error "An error ocurred while building the json respose: ", error=resp.error
    return RestApiResponse.internalServerError(fmt("An error ocurred while building the json respose: {resp.error}"))

  return resp.get()

proc filterPostPutSubscriptionRequestHandler(node: WakuNode,
                                             contentBody: Option[ContentBody],
                                             cache: MessageCache):
                                          Future[RestApiResponse]
                                          {.async.} =
  ## handles any filter subscription requests, adds or modifies.

  let decodedBody = decodeRequestBody[FilterSubscribeRequest](contentBody)

  if decodedBody.isErr():
    return makeRestResponse("unknown", FilterSubscribeError.badRequest(fmt("Failed to decode request: {decodedBody.error}")))

  let req: FilterSubscribeRequest = decodedBody.value()

  let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)

  if peerOpt.isNone():
    return makeRestResponse(req.requestId, FilterSubscribeError.serviceUnavailable("No suitable peers"))

  let subFut = node.filterSubscribe(req.pubsubTopic,
                                      req.contentFilters,
                                      peerOpt.get())

  if not await subFut.withTimeout(futTimeoutForSubscriptionProcessing):
    error "Failed to subscribe to contentFilters do to timeout!"
    return makeRestResponse(req.requestId, FilterSubscribeError.serviceUnavailable("Subscription request timed out"))

  # Successfully subscribed to all content filters
  for cTopic in req.contentFilters:
    cache.subscribe(cTopic)

  return makeRestResponse(req.requestId, subFut.read())

proc installFilterPostSubscriptionsHandler(router: var RestRouter,
                                           node: WakuNode,
                                           cache: MessageCache) =
  router.api(MethodPost, ROUTE_FILTER_SUBSCRIPTIONS) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a pubsubTopic
    debug "post", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    let response = await filterPostPutSubscriptionRequestHandler(node, contentBody, cache)
    return response

proc installFilterPutSubscriptionsHandler(router: var RestRouter,
                                          node: WakuNode,
                                          cache: MessageCache) =
  router.api(MethodPut, ROUTE_FILTER_SUBSCRIPTIONS) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Modifies a subscribtion of a node to a list of contentTopics of a pubsubTopic
    debug "put", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    let response = await filterPostPutSubscriptionRequestHandler(node, contentBody, cache)
    return response

proc installFilterDeleteSubscriptionsHandler(router: var RestRouter,
                                             node: WakuNode,
                                             cache: MessageCache) =
  router.api(MethodDelete, ROUTE_FILTER_SUBSCRIPTIONS) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    debug "delete", ROUTE_FILTER_SUBSCRIPTIONS, contentBody

    let decodedBody = decodeRequestBody[FilterUnsubscribeRequest](contentBody)

    if decodedBody.isErr():
      return makeRestResponse("unknown",
                FilterSubscribeError.badRequest(fmt("Failed to decode request: {decodedBody.error}")))

    let req: FilterUnsubscribeRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)

    if peerOpt.isNone():
      return makeRestResponse(req.requestId,
                FilterSubscribeError.serviceUnavailable("No suitable peers"))

    let unsubFut = node.filterUnsubscribe(req.pubsubTopic, req.contentFilters, peerOpt.get())
    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return makeRestResponse(req.requestId,
                FilterSubscribeError.serviceUnavailable(
                            "Failed to unsubscribe from contentFilters due to timeout!"))

    # Successfully subscribed to all content filters
    for cTopic in req.contentFilters:
      cache.unsubscribe(cTopic)

    # Successfully unsubscribed from all requested contentTopics
    return makeRestResponse(req.requestId, unsubFut.read())

proc installFilterDeleteAllSubscriptionsHandler(router: var RestRouter,
                                             node: WakuNode,
                                             cache: MessageCache) =
  router.api(MethodDelete, ROUTE_FILTER_ALL_SUBSCRIPTIONS) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    debug "delete", ROUTE_FILTER_ALL_SUBSCRIPTIONS, contentBody

    let decodedBody = decodeRequestBody[FilterUnsubscribeAllRequest](contentBody)

    if decodedBody.isErr():
      return makeRestResponse("unknown",
                FilterSubscribeError.badRequest(fmt("Failed to decode request: {decodedBody.error}")))

    let req: FilterUnsubscribeAllRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)

    if peerOpt.isNone():
      return makeRestResponse(req.requestId,
                FilterSubscribeError.serviceUnavailable("No suitable peers"))

    let unsubFut = node.filterUnsubscribeAll(peerOpt.get())
    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return makeRestResponse(req.requestId,
                FilterSubscribeError.serviceUnavailable(
                            "Failed to unsubscribe from all contentFilters due to timeout!"))

    cache.unsubscribeAll()

    # Successfully unsubscribed from all requested contentTopics
    return makeRestResponse(req.requestId, unsubFut.read())

const ROUTE_FILTER_SUBSCRIBER_PING* = "/filter/v2/subscriptions/{requestId}"

proc installFilterPingSubscriberHandler(router: var RestRouter,
                                        node: WakuNode) =
  router.api(MethodGet, ROUTE_FILTER_SUBSCRIBER_PING) do (requestId: string) -> RestApiResponse:
    ## Checks if a node has valid subscription or not.
    debug "get", ROUTE_FILTER_SUBSCRIBER_PING, requestId

    let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)
    if peerOpt.isNone():
      return makeRestResponse(requestId.get(),
                FilterSubscribeError.serviceUnavailable("No suitable remote filter peers"))

    let pingFutRes = node.wakuFilterClient.ping(peerOpt.get())

    if not await pingFutRes.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to ping filter service peer due to timeout!"
      return makeRestResponse(requestId.get(),
                FilterSubscribeError.serviceUnavailable("Ping timed out"))

    return makeRestResponse(requestId.get(), pingFutRes.read())

const ROUTE_FILTER_MESSAGES* = "/filter/v2/messages/{contentTopic}"

proc installFilterGetMessagesHandler(router: var RestRouter,
                                     node: WakuNode,
                                     cache: MessageCache) =


  let pushHandler : FilterPushHandler = proc (pubsubTopic: PubsubTopic,
                                              msg: WakuMessage)
                                              {.async, gcsafe, closure.} =
    cache.addMessage(msg.contentTopic, msg)

  node.wakuFilterClient.registerPushHandler(pushHandler)

  router.api(MethodGet, ROUTE_FILTER_MESSAGES) do (contentTopic: string) -> RestApiResponse:
    ## Returns all WakuMessages received on a specified content topic since the
    ## last time this method was called
    ## TODO: ability to specify a return message limit, maybe use cursor to control paging response.
    debug "get", ROUTE_FILTER_MESSAGES, contentTopic=contentTopic

    if contentTopic.isErr():
      return RestApiResponse.badRequest("Missing contentTopic")

    let contentTopic = contentTopic.get()

    let msgRes = cache.getMessages(contentTopic, clear=true)
    if msgRes.isErr():
      return RestApiResponse.badRequest("Not subscribed to topic: " & contentTopic)

    let data = FilterGetMessagesResponse(msgRes.get().map(toFilterWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status=Http200)
    if resp.isErr():
      error "An error ocurred while building the json respose: ", error=resp.error
      return RestApiResponse.internalServerError("An error ocurred while building the json respose")

    return resp.get()

proc installFilterRestApiHandlers*(router: var RestRouter,
                                   node: WakuNode,
                                   cache: MessageCache) =
  installFilterPingSubscriberHandler(router, node)
  installFilterPostSubscriptionsHandler(router, node, cache)
  installFilterPutSubscriptionsHandler(router, node, cache)
  installFilterDeleteSubscriptionsHandler(router, node, cache)
  installFilterDeleteAllSubscriptionsHandler(router, node, cache)
  installFilterGetMessagesHandler(router, node, cache)
