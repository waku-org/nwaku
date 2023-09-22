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
  ../../../waku_node,
  ../../../waku_relay/protocol,
  ../../../waku_rln_relay,
  ../../../waku_rln_relay/rln/wrappers,
  ../../../node/waku_node,
  ../../message_cache,
  ../../cache_handlers,
  ../serdes,
  ../responses,
  ./types

from std/times import getTime
from std/times import toUnix


export types


logScope:
  topics = "waku node rest relay_api"


##### Topic cache

const futTimeout* = 5.seconds # Max time to wait for futures


#### Request handlers

const ROUTE_RELAY_SUBSCRIPTIONSV1* = "/relay/v1/subscriptions"
const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{topic}"
const ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1* = "/relay/v1/auto/subscriptions"
const ROUTE_RELAY_AUTO_MESSAGESV1* = "/relay/v1/auto/messages/{topic}"

proc installRelayApiHandlers*(router: var RestRouter, node: WakuNode, cache: MessageCache[string]) =
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

    for pubsubTopic in newTopics:
      cache.subscribe(pubsubTopic)
      node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(messageCacheHandler(cache)))

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
    for pubsubTopic in req:
      node.unsubscribe((kind: PubsubUnsub, topic: pubsubTopic))
      cache.unsubscribe(pubsubTopic)

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

    # ensure the node is subscribed to the topic. otherwise it risks publishing
    # to a topic with no connected peers
    if pubSubTopic notin node.wakuRelay.subscribedTopics():
      return RestApiResponse.badRequest("Failed to publish: Node not subscribed to topic: " & pubsubTopic)

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

    var message = resMessage.get()

    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      # append the proof to the message
      let success = node.wakuRlnRelay.appendRLNProof(message,
                                                    float64(getTime().toUnix()))
      if not success:
        return RestApiResponse.internalServerError("Failed to publish: error appending RLN proof to message")

      # validate the message before sending it
      let result = node.wakuRlnRelay.validateMessage(message)
      if result == MessageValidationResult.Invalid:
        return RestApiResponse.internalServerError("Failed to publish: invalid RLN proof")
      elif result == MessageValidationResult.Spam:
        return RestApiResponse.badRequest("Failed to publish: limit exceeded, try again later")
      elif result == MessageValidationResult.Valid:
        debug "RLN proof validated successfully", pubSubTopic=pubSubTopic
      else:
        return RestApiResponse.internalServerError("Failed to publish: unknown RLN proof validation result")

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message", pubSubTopic=pubSubTopic, rln=defined(rln)
    if not (waitFor node.publish(some(pubSubTopic), resMessage.value).withTimeout(futTimeout)):
      error "Failed to publish message to topic", pubSubTopic=pubSubTopic
      return RestApiResponse.internalServerError("Failed to publish: timedout")

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

    for contentTopic in newTopics:
      cache.subscribe(contentTopic)
      node.subscribe((kind: ContentSub, topic: contentTopic), some(autoMessageCacheHandler(cache)))

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
    for contentTopic in req:
      cache.unsubscribe(contentTopic)
      node.unsubscribe((kind: ContentUnsub, topic: contentTopic))

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

    if reqResult.value.contentTopic.isNone():
      return RestApiResponse.badRequest()

    let resMessage = reqResult.value.toWakuMessage(version = 0)
    if resMessage.isErr():
      return RestApiResponse.badRequest()

    var message = resMessage.get()

    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      # append the proof to the message
      let success = node.wakuRlnRelay.appendRLNProof(message,
                                                    float64(getTime().toUnix()))
      if not success:
        return RestApiResponse.internalServerError("Failed to publish: error appending RLN proof to message")

      # validate the message before sending it
      let result = node.wakuRlnRelay.validateMessage(message)
      if result == MessageValidationResult.Invalid:
        return RestApiResponse.internalServerError("Failed to publish: invalid RLN proof")
      elif result == MessageValidationResult.Spam:
        return RestApiResponse.badRequest("Failed to publish: limit exceeded, try again later")
      elif result == MessageValidationResult.Valid:
        debug "RLN proof validated successfully", contentTopic=message.contentTopic
      else:
        return RestApiResponse.internalServerError("Failed to publish: unknown RLN proof validation result")

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message", contentTopic=message.contentTopic, rln=defined(rln)
    if not (waitFor node.publish(none(PubSubTopic), message).withTimeout(futTimeout)):
      error "Failed to publish message to topic", contentTopic=message.contentTopic
      return RestApiResponse.internalServerError("Failed to publish: timedout")

    return RestApiResponse.ok()