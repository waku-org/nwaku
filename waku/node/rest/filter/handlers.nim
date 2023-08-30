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
  ../../../waku_filter_v2,
  ../../message_cache,
  ../../peer_manager,
  ../../waku_node,
  ../serdes,
  ../responses,
  ./types
  
export types

logScope:
  topics = "waku node rest filter_api"

const futTimeoutForSubscriptionProcessing* = 5.seconds 

#### Request handlers

const ROUTE_FILTER_SUBSCRIPTIONSV1* = "/filter/v1/subscriptions"

const filterMessageCacheDefaultCapacity* = 30

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

proc installFilterPostSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode) =
  router.api(MethodPost, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a pubsubTopic
    # debug "post_waku_v2_filter_v1_subscriptions"

    let decodedBody = decodeRequestBody[FilterSubscriptionsRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error

    let req: FilterSubscriptionsRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)

    if peerOpt.isNone():
      return RestApiResponse.internalServerError("No suitable remote filter peers")

    # TODO req/res via channels. Would require AsyncChannel[T] impl.
    let subFut = node.wakuFilterClient.subscribe(peerOpt.get(), req.pubsubTopic, req.contentFilters)

    if not await subFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to subscribe to contentFilters do to timeout!"
      return RestApiResponse.internalServerError("Failed to subscribe to contentFilters")

    return RestApiResponse.ok()

proc installFilterDeleteSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode) =
  router.api(MethodDelete, ROUTE_FILTER_SUBSCRIPTIONSV1) do (contentBody: Option[ContentBody]) -> RestApiResponse:
    ## Subscribes a node to a list of contentTopics of a PubSub topic
    # debug "delete_waku_v2_filter_v1_subscriptions"

    let decodedBody = decodeRequestBody[FilterSubscriptionsRequest](contentBody)

    if decodedBody.isErr():
      return decodedBody.error

    let req: FilterSubscriptionsRequest = decodedBody.value()

    let peerOpt = node.peerManager.selectPeer(WakuFilterSubscribeCodec)

    if peerOpt.isNone():
      return RestApiResponse.internalServerError("No suitable remote filter peers")

    # TODO req/res via channels. Would require AsyncChannel[T] impl.
    let unsubFut = node.wakuFilterClient.unsubscribe(peerOpt.get(), req.pubsubTopic, req.contentFilters)

    if not await unsubFut.withTimeout(futTimeoutForSubscriptionProcessing):
      error "Failed to unsubscribe from contentFilters due to timeout!"
      return RestApiResponse.internalServerError("Failed to unsubscribe from contentFilters")

    return RestApiResponse.ok()

proc installFilterApiHandlers*(router: var RestRouter, node: WakuNode) =
  installFilterPostSubscriptionsV1Handler(router, node)
  installFilterDeleteSubscriptionsV1Handler(router, node)
