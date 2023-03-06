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
  ../serdes,
  ../responses,
  ./types,
  ./topic_cache

export types


logScope:
  topics = "waku node rest relay_api"


##### Topic cache

const futTimeout* = 5.seconds # Max time to wait for futures


#### Request handlers

const ROUTE_RELAY_SUBSCRIPTIONSV1* = "/relay/v1/subscriptions"

proc installRelayPostSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, cache: TopicCache) =

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

    for topic in req:
      if cache.isSubscribed(string(topic)):
        # Only subscribe to topics for which we have no subscribed topic handlers yet
        continue

      cache.subscribe(string(topic))
      node.subscribe(string(topic), cache.messageHandler())

    return RestApiResponse.ok()


proc installRelayDeleteSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, cache: TopicCache) =
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
    for topic in req:
      node.unsubscribeAll(string(topic))
      cache.unsubscribe(string(topic))

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()


const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{topic}"

proc installRelayGetMessagesV1Handler*(router: var RestRouter, node: WakuNode, cache: TopicCache) =
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

proc installRelayPostMessagesV1Handler*(router: var RestRouter, node: WakuNode) =
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

    if not (waitFor node.publish(pubSubTopic, resMessage.value).withTimeout(futTimeout)):
      error "Failed to publish message to topic", topic=pubSubTopic
      return RestApiResponse.internalServerError()

    return RestApiResponse.ok()


proc installRelayApiHandlers*(router: var RestRouter, node: WakuNode, cache: TopicCache) =
  installRelayPostSubscriptionsV1Handler(router, node, cache)
  installRelayDeleteSubscriptionsV1Handler(router, node, cache)
  installRelayGetMessagesV1Handler(router, node, cache)
  installRelayPostMessagesV1Handler(router, node)
