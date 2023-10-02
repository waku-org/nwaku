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
  ../../../waku_rln_relay,
  ../../message_cache,
  ../serdes,
  ../responses,
  ./types

export types

logScope:
  topics = "waku node rest relay_api"

const futTimeout* = 5.seconds # Max time to wait for futures

#### Request handlers

const ROUTE_RELAY_SUBSCRIPTIONSV1* = "/relay/v1/subscriptions"
const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{pubsubTopic}"
const ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1* = "/relay/v1/auto/subscriptions"
const ROUTE_RELAY_AUTO_MESSAGESV1* = "/relay/v1/auto/messages/{contentTopic}"
const ROUTE_RELAY_AUTO_MESSAGESV1_NO_TOPIC* = "/relay/v1/auto/messages"

proc installRelaySubscriptionHandlers*(router: var RestRouter, handler: SubscriptionsHandler) =
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
    let reqResult = decodeFromJsonBytes(seq[PubsubTopic], reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: seq[PubsubTopic] = reqResult.get()

    await handler(PubsubSub, req)

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
    let reqResult = decodeFromJsonBytes(seq[PubsubTopic], reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: seq[PubsubTopic] = reqResult.get()

    await handler(PubsubUnsub, req)

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()

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
    let reqResult = decodeFromJsonBytes(seq[ContentTopic], reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: seq[ContentTopic] = reqResult.get()

    await handler(ContentSub, req)

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
    let reqResult = decodeFromJsonBytes(seq[ContentTopic], reqBodyData)
    if reqResult.isErr():
      return RestApiResponse.badRequest()

    let req: seq[ContentTopic] = reqResult.get()

    await handler(ContentUnsub, req)

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()

proc installRelayApiMessageHandlers*(router: var RestRouter, cache: MessageCache[string]) =
  router.api(MethodGet, ROUTE_RELAY_MESSAGESV1) do (pubsubTopic: string) -> RestApiResponse:
    # ## Returns all WakuMessages received on a PubSub topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_messages", topic=topic

    if pubsubTopic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = pubsubTopic.get()

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
  
  router.api(MethodGet, ROUTE_RELAY_AUTO_MESSAGESV1) do (contentTopic: string) -> RestApiResponse:
    # ## Returns all WakuMessages received on a content topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_auto_messages", topic=topic

    if contentTopic.isErr():
      return RestApiResponse.badRequest()
    let contentTopic = contentTopic.get()

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

proc installRelayApiPublishHandlers*(router: var RestRouter, handler: PublishHandler) =
  router.api(MethodPost, ROUTE_RELAY_AUTO_MESSAGESV1_NO_TOPIC) do (contentBody: Option[ContentBody]) -> RestApiResponse:
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

    if reqResult.value.contentTopic.isNone():
      return RestApiResponse.badRequest()

    let resMessage = reqResult.value.toWakuMessage(version = 0)
    if resMessage.isErr():
      return RestApiResponse.badRequest()

    let message = resMessage.get()

    let publishFut = handler(none(PubSubTopic), message)

    if not await publishFut.withTimeout(futTimeout):
      error "Failed to publish message to topic", contentTopic=message.contentTopic
      return RestApiResponse.internalServerError("Failed to publish: timedout")

    let res = publishFut.read()
    if res.isErr():
      return RestApiResponse.internalServerError(res.error)

    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_RELAY_MESSAGESV1) do (pubsubTopic: string, contentBody: Option[ContentBody]) -> RestApiResponse:
    if pubsubTopic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = pubsubTopic.get()

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

    let publishFut = handler(some(pubSubTopic), resMessage.get())

    if not await publishFut.withTimeout(futTimeout):
      error "Failed to publish message to topic", pubSubTopic=pubSubTopic
      return RestApiResponse.internalServerError("Failed to publish: timedout")

    let res = publishFut.read()
    if res.isErr():
      return RestApiResponse.internalServerError(res.error)

    return RestApiResponse.ok()