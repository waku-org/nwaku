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
  topics = "waku node rest filter_api"


##### Topic cache

const futTimeout* = 5.seconds # Max time to wait for futures


#### Request handlers

const ROUTE_FILTER_SUBSCRIPTIONSV1* = "/filter/v1/subscriptions"

const filterMessageCacheDefaultCapacity* = 30

type
  MessageCache* = message_cache.MessageCache[ContentTopic]


func decodeRequestBody[T](contentBody: Option[ContentBody]) : Result[T, RestApiResponse] =
  # Check the request body
  if contentBody.isNone():
    return err(RestApiResponse.badRequest())

  let reqBodyContentType = MediaType.init($contentBody.get().contentType)
  if reqBodyContentType != MIMETYPE_JSON:
    return err(RestApiResponse.badRequest())

  let reqBodyData = contentBody.get().data

  let reqResult = decodeFromJsonBytes(T, reqBodyData)
  if reqResult.isErr():
    return err(RestApiResponse.badRequest())

  return ok(reqResult.get())

proc installFilterPostSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, cache: MessageCache) =

  router.api(MethodPost, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of contentTopics of a pubsubTopic
    # debug "post_waku_v2_filter_v1_subscriptions"

    let decodedBody = decodeRequestBody[FilterSubscriptionsRequest](contentBody)

    if decodedBody.isErr():
      error "Failed to decode body", error=decodedBody.error()
      return decodedBody.error()

    let req: FilterSubscriptionsRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuFilterCodec)

    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote filter peers")

    let handler: FilterPushHandler = proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async, gcsafe, closure.} =
        cache.addMessage(msg.contentTopic, msg)

    let subFut = node.filterSubscribe(req.pubsubTopic, req.contentFilters, handler, peerOpt.get())
    if not await subFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to subscribe to contentFilters")

    # Successfully subscribed to all content filters
    for cTopic in req.contentFilters:
      cache.subscribe(cTopic)

    return RestApiResponse.ok()


proc installFilterDeleteSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, cache: MessageCache) =
  router.api(MethodDelete, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    # ## Subscribes a node to a list of contentTopics of a PubSub topic
    # debug "delete_waku_v2_filter_v1_subscriptions"

    let decodedBody = decodeRequestBody[FilterSubscriptionsRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error()

    let req: FilterSubscriptionsRequest = decodedBody.value()

    let unsubFut = node.unsubscribe(req.pubsubTopic, req.contentFilters)
    if not await unsubFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to unsubscribe from contentFilters")

    for cTopic in req.contentFilters:
      cache.unsubscribe(cTopic)

    # Successfully unsubscribed from all requested contentTopics
    return RestApiResponse.ok()


const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{contentTopic}"

proc installFilterGetMessagesV1Handler*(router: var RestRouter, node: WakuNode, cache: MessageCache) =
  router.api(MethodGet, ROUTE_RELAY_MESSAGESV1) do (contentTopic: string) -> RestApiResponse:
    # ## Returns all WakuMessages received on a specified content topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_filter_v1_messages", contentTopic=contentTopic

    if contentTopic.isErr():
      return RestApiResponse.badRequest()
    let contentTopic = contentTopic.get()

    if not cache.isSubscribed(contentTopic):
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    let msgRes = cache.getMessages(contentTopic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    let data = FilterGetMessagesResponse(msgRes.get().map(toFilterWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error
      return RestApiResponse.internalServerError()

    return resp.get()


proc installFilterApiHandlers*(router: var RestRouter, node: WakuNode, cache: MessageCache) =
  installFilterPostSubscriptionsV1Handler(router, node, cache)
  installFilterDeleteSubscriptionsV1Handler(router, node, cache)
  installFilterGetMessagesV1Handler(router, node, cache)
