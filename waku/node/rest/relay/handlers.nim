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
  ../../waku_node,
  ../../../waku_core,
  ../serdes,
  ../responses,
  ./types,
  ./topic_cache

export types


logScope:
  topics = "waku node rest relay_api"


#### Request handlers

const ROUTE_RELAY_SUBSCRIPTIONSV1* = "/relay/v1/subscriptions"
const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{topic}"
const ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1* = "/relay/v1/auto/subscriptions"
const ROUTE_RELAY_AUTO_MESSAGESV1* = "/relay/v1/auto/messages/{topic}"

proc installRelayApiHandlers*(
  router: var RestRouter,
  subscriptionsTx: AsyncEventQueue[SubscriptionEvent],
  messageTx: AsyncEventQueue[(PubsubTopic, WakuMessage)],
  cache: MessageCache[string],
  ) =
  router.api(MethodPost, ROUTE_RELAY_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of PubSub topics
    # debug "post_waku_v2_relay_v1_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayPostSubscriptionsRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: RelayPostSubscriptionsRequest = reqResult.get()

    # Only subscribe to topics for which we have no subscribed topic handlers yet
    let newTopics = req.filterIt(not cache.isSubscribed(it))

    for topic in newTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: PubsubSub, pubsubSub: topic))

    return RestApiResponse.ok()

  router.api(MethodDelete, ROUTE_RELAY_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of PubSub topics
    # debug "delete_waku_v2_relay_v1_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayDeleteSubscriptionsRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: RelayDeleteSubscriptionsRequest = reqResult.get()

    # Unsubscribe all handlers from requested topics
    let subscribedTopics = req.filterIt(cache.isSubscribed(it))

    for topic in subscribedTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: PubsubUnsub, pubsubUnsub: topic))

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_RELAY_MESSAGESV1) do (topic: string) -> RestApiResponse:
    # ## Returns all WakuMessages received on a PubSub topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_messages", topic=topic

    if topic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = topic.get()

    let messages = cache.getMessages(pubSubTopic, clear=true)
    if messages.isErr():
      debug "Not subscribed to topic", topic=pubSubTopic
      return RestApiResponse.notFound()

    let data = RelayGetMessagesResponse(messages.get().map(toRelayWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error
      return RestApiResponse.internalServerError()

    return resp.get()

  router.api(MethodPost, ROUTE_RELAY_MESSAGESV1) do (topic: string, contentBody: Option[ContentBody]) -> RestApiResponse:
    if topic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = topic.get()

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayPostMessagesRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let resMessage = reqResult.value.toWakuMessage(version = 0)
    if resMessage.isErr():
      return RestApiResponse.badRequest()
    let message = resMesage.get()

    # TODO wait for an answer. Would require AsyncChannel[T]
    messageTx.emit((pubSubTopic, message))

    return RestApiResponse.ok()

  # Autosharding API

  router.api(MethodPost, ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of content topics
    # debug "post_waku_v2_relay_v1_auto_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayPostSubscriptionsRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: RelayPostSubscriptionsRequest = reqResult.get()

    # Only subscribe to topics for which we have no subscribed topic handlers yet
    let newTopics = req.filterIt(not cache.isSubscribed(it))

    for topic in newTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentSub, contentSub: topic))

    return RestApiResponse.ok()

  router.api(MethodDelete, ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of content topics
    # debug "delete_waku_v2_relay_v1_auto_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayDeleteSubscriptionsRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: RelayDeleteSubscriptionsRequest = reqResult.get()

    # Unsubscribe all handlers from requested topics
    let subscribedTopics = req.filterIt(cache.isSubscribed(it))

    for topic in subscribedTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentUnsub, contentUnsub: topic))

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_RELAY_AUTO_MESSAGESV1) do (topic: string) -> RestApiResponse:
    # ## Returns all WakuMessages received on a content topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_auto_messages", topic=topic

    if topic.isErr():
      return RestApiResponse.badRequest()
    let contentTopic = topic.get()

    let messages = cache.getMessages(contentTopic, clear=true)
    if messages.isErr():
      debug "Not subscribed to topic", topic=contentTopic
      return RestApiResponse.notFound()

    let data = RelayGetMessagesResponse(messages.get().map(toRelayWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error
      return RestApiResponse.internalServerError()

    return resp.get()

  router.api(MethodPost, ROUTE_RELAY_AUTO_MESSAGESV1) do (topic: string, contentBody: Option[ContentBody]) -> RestApiResponse:
    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqBodyContentType = MediaType.init($contentBody.get().contentType)
    if reqBodyContentType != MIMETYPE_JSON:
      return RestApiResponse.badRequest()

    let reqBodyData = contentBody.get().data
    let reqResult = decodeFromJsonBytes(RelayPostMessagesRequest, reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let resMessage = reqResult.value.toWakuMessage(version = 0)
    if resMessage.isErr():
      return RestApiResponse.badRequest()
    let message = resMessage.get()

    let pubsubTopicRes = getShard(message.contentTopic)
    if pubsubTopicRes.isErr():
      raise newException(ValueError, pubsubTopicRes.error)

    # TODO wait for an answer. Would require AsyncChannel[T]
    messageTx.emit((pubsubTopicRes.get(), message))


    return RestApiResponse.ok()