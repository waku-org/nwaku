when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
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
  ../../../waku_filter/client,
  ../../message_cache,
  ../../peer_manager,
  ../../waku_node,
  ../serdes,
  ../responses,
  ./types

export types

logScope:
  topics = "waku node rest filter_api v1"

const futTimeoutForSubscriptionProcessing* = 5.seconds

#### Request handlers

const ROUTE_FILTER_SUBSCRIPTIONSV1* = "/filter/v1/subscriptions"

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

proc installFilterV1PostSubscriptionsV1Handler*(router: var RestRouter,
                                              node: WakuNode,
                                              cache: MessageCache) =
  let pushHandler: FilterPushHandler =
          proc(pubsubTopic: PubsubTopic,
               msg: WakuMessage) {.async, gcsafe, closure.} =
            cache.addMessage(msg.contentTopic, msg)

  router.api(MethodPost, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a pubsubTopic
    debug "post", ROUTE_FILTER_SUBSCRIPTIONSV1, contentBody

    let decodedBody = decodeRequestBody[FilterLegacySubscribeRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error

    let req: FilterLegacySubscribeRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuLegacyFilterCodec)

    if peerOpt.isNone():
      return RestApiResponse.internalServerError("No suitable remote filter peers")

    let subFut = node.legacyFilterSubscribe(req.pubsubTopic,
                                            req.contentFilters,
                                            pushHandler,
                                            peerOpt.get())

    if not await subFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to subscribe to contentFilters do to timeout!"
      return RestApiResponse.internalServerError("Failed to subscribe to contentFilters")

    # Successfully subscribed to all content filters
    for cTopic in req.contentFilters:
      cache.subscribe(cTopic)

    return RestApiResponse.ok()

proc installFilterV1DeleteSubscriptionsV1Handler*(router: var RestRouter,
                                                node: WakuNode,
                                                cache: MessageCache) =
  router.api(MethodDelete, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    debug "delete", ROUTE_FILTER_SUBSCRIPTIONSV1, contentBody

    let decodedBody = decodeRequestBody[FilterLegacySubscribeRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error

    let req: FilterLegacySubscribeRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuLegacyFilterCodec)

    if peerOpt.isNone():
      return RestApiResponse.internalServerError("No suitable remote filter peers")

    let unsubFut = node.legacyFilterUnsubscribe(req.pubsubTopic, req.contentFilters, peerOpt.get())
    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return RestApiResponse.internalServerError("Failed to unsubscribe from contentFilters")

    for cTopic in req.contentFilters:
      cache.unsubscribe(cTopic)

    # Successfully unsubscribed from all requested contentTopics
    return RestApiResponse.ok()

const ROUTE_FILTER_MESSAGESV1* = "/filter/v1/messages/{contentTopic}"

proc installFilterV1GetMessagesV1Handler*(router: var RestRouter,
                                        node: WakuNode,
                                        cache: MessageCache) =
  router.api(MethodGet, ROUTE_FILTER_MESSAGESV1) do (contentTopic: string) -> RestApiResponse:
    ## Returns all WakuMessages received on a specified content topic since the
    ## last time this method was called
    ## TODO: ability to specify a return message limit
    debug "get", ROUTE_FILTER_MESSAGESV1, contentTopic=contentTopic

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

proc installLegacyFilterRestApiHandlers*(router: var RestRouter,
                               node: WakuNode,
                               cache: MessageCache) =
  installFilterV1PostSubscriptionsV1Handler(router, node, cache)
  installFilterV1DeleteSubscriptionsV1Handler(router, node, cache)
  installFilterV1GetMessagesV1Handler(router, node, cache)
