when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  stew/[byteutils, results],
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/route,
  presto/common
import
  ../../../waku_node,
  ../../../waku_relay/protocol,
  ../../../waku_rln_relay,
  ../../../node/waku_node,
  ../../message_cache,
  ../../handlers,
  ../serdes,
  ../responses,
  ../rest_serdes,
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
const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{pubsubTopic}"
const ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1* = "/relay/v1/auto/subscriptions"
const ROUTE_RELAY_AUTO_MESSAGESV1* = "/relay/v1/auto/messages/{contentTopic}"
const ROUTE_RELAY_AUTO_MESSAGESV1_NO_TOPIC* = "/relay/v1/auto/messages"

proc installRelayApiHandlers*(
    router: var RestRouter, node: WakuNode, cache: MessageCache
) =
  router.api(MethodOptions, ROUTE_RELAY_SUBSCRIPTIONSV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_RELAY_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes a node to a list of PubSub topics

    debug "post_waku_v2_relay_v1_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let req: seq[PubsubTopic] = decodeRequestBody[seq[PubsubTopic]](contentBody).valueOr:
      return error

    # Only subscribe to topics for which we have no subscribed topic handlers yet
    let newTopics = req.filterIt(not cache.isPubsubSubscribed(it))

    for pubsubTopic in newTopics:
      cache.pubsubSubscribe(pubsubTopic)
      node.subscribe(
        (kind: PubsubSub, topic: pubsubTopic), some(messageCacheHandler(cache))
      )

    return RestApiResponse.ok()

  router.api(MethodDelete, ROUTE_RELAY_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    # ## Subscribes a node to a list of PubSub topics
    # debug "delete_waku_v2_relay_v1_subscriptions"

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let req: seq[PubsubTopic] = decodeRequestBody[seq[PubsubTopic]](contentBody).valueOr:
      return error

    # Unsubscribe all handlers from requested topics
    for pubsubTopic in req:
      cache.pubsubUnsubscribe(pubsubTopic)
      node.unsubscribe((kind: PubsubUnsub, topic: pubsubTopic))

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok()

  router.api(MethodOptions, ROUTE_RELAY_MESSAGESV1) do(
    pubsubTopic: string
  ) -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_RELAY_MESSAGESV1) do(
    pubsubTopic: string
  ) -> RestApiResponse:
    # ## Returns all WakuMessages received on a PubSub topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_messages", topic=topic

    if pubsubTopic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = pubsubTopic.get()

    let messages = cache.getMessages(pubSubTopic, clear = true)
    if messages.isErr():
      debug "Not subscribed to topic", topic = pubSubTopic
      return RestApiResponse.notFound()

    let data = RelayGetMessagesResponse(messages.get().map(toRelayWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status = Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error = resp.error
      return RestApiResponse.internalServerError()

    return resp.get()

  router.api(MethodPost, ROUTE_RELAY_MESSAGESV1) do(
    pubsubTopic: string, contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    if pubsubTopic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = pubsubTopic.get()

    # ensure the node is subscribed to the topic. otherwise it risks publishing
    # to a topic with no connected peers
    if pubSubTopic notin node.wakuRelay.subscribedTopics():
      return RestApiResponse.badRequest(
        "Failed to publish: Node not subscribed to topic: " & pubsubTopic
      )

    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let reqWakuMessage: RelayWakuMessage = decodeRequestBody[RelayWakuMessage](
      contentBody
    ).valueOr:
      return error

    var message: WakuMessage = reqWakuMessage.toWakuMessage(version = 0).valueOr:
      return RestApiResponse.badRequest($error)

    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      # append the proof to the message

      node.wakuRlnRelay.appendRLNProof(message, float64(getTime().toUnix())).isOkOr:
        return RestApiResponse.internalServerError(
          "Failed to publish: error appending RLN proof to message: " & $error
        )

    # (await node.wakuRelay.validateMessage(pubsubTopic, message)).isOkOr:
    #   return RestApiResponse.badRequest("Failed to publish: " & error)

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message",
      pubSubTopic = pubSubTopic, rln = not node.wakuRlnRelay.isNil()
    if not (waitFor node.publish(some(pubSubTopic), message).withTimeout(futTimeout)):
      error "Failed to publish message to topic", pubSubTopic = pubSubTopic
      return RestApiResponse.internalServerError("Failed to publish: timedout")

    return RestApiResponse.ok()

  # Autosharding API

  router.api(MethodOptions, ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Subscribes a node to a list of content topics.

    debug "post_waku_v2_relay_v1_auto_subscriptions"

    let req: seq[ContentTopic] = decodeRequestBody[seq[ContentTopic]](contentBody).valueOr:
      return error

    # Only subscribe to topics for which we have no subscribed topic handlers yet
    let newTopics = req.filterIt(not cache.isContentSubscribed(it))

    for contentTopic in newTopics:
      cache.contentSubscribe(contentTopic)
      node.subscribe(
        (kind: ContentSub, topic: contentTopic), some(messageCacheHandler(cache))
      )

    return RestApiResponse.ok()

  router.api(MethodDelete, ROUTE_RELAY_AUTO_SUBSCRIPTIONSV1) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    ## Unsubscribes a node from a list of content topics.

    debug "delete_waku_v2_relay_v1_auto_subscriptions"

    let req: seq[ContentTopic] = decodeRequestBody[seq[ContentTopic]](contentBody).valueOr:
      return error

    for contentTopic in req:
      cache.contentUnsubscribe(contentTopic)
      node.unsubscribe((kind: ContentUnsub, topic: contentTopic))

    return RestApiResponse.ok()

  router.api(MethodOptions, ROUTE_RELAY_AUTO_MESSAGESV1) do(
    contentTopic: string
  ) -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodGet, ROUTE_RELAY_AUTO_MESSAGESV1) do(
    contentTopic: string
  ) -> RestApiResponse:
    ## Returns all WakuMessages received on a content topic since the
    ## last time this method was called.

    debug "get_waku_v2_relay_v1_auto_messages", contentTopic = contentTopic

    let contentTopic = contentTopic.valueOr:
      return RestApiResponse.badRequest($error)

    let messages = cache.getAutoMessages(contentTopic, clear = true).valueOr:
      debug "Not subscribed to topic", topic = contentTopic
      return RestApiResponse.notFound(contentTopic)

    let data = RelayGetMessagesResponse(messages.map(toRelayWakuMessage))

    return RestApiResponse.jsonResponse(data, status = Http200).valueOr:
      debug "An error ocurred while building the json respose", error = error
      return RestApiResponse.internalServerError($error)

  router.api(MethodOptions, ROUTE_RELAY_AUTO_MESSAGESV1_NO_TOPIC) do() -> RestApiResponse:
    return RestApiResponse.ok()

  router.api(MethodPost, ROUTE_RELAY_AUTO_MESSAGESV1_NO_TOPIC) do(
    contentBody: Option[ContentBody]
  ) -> RestApiResponse:
    # Check the request body
    if contentBody.isNone():
      return RestApiResponse.badRequest()

    let req: RelayWakuMessage = decodeRequestBody[RelayWakuMessage](contentBody).valueOr:
      return error

    if req.contentTopic.isNone():
      return RestApiResponse.badRequest()

    var message: WakuMessage = req.toWakuMessage(version = 0).valueOr:
      return RestApiResponse.badRequest()

    let pubsubTopic = node.wakuSharding.getShard(message.contentTopic).valueOr:
      let msg = "Autosharding error: " & error
      error "publish error", msg = msg
      return RestApiResponse.badRequest("Failed to publish. " & msg)

    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      node.wakuRlnRelay.appendRLNProof(message, float64(getTime().toUnix())).isOkOr:
        return RestApiResponse.internalServerError(
          "Failed to publish: error appending RLN proof to message: " & $error
        )

    # (await node.wakuRelay.validateMessage(pubsubTopic, message)).isOkOr:
    #   return RestApiResponse.badRequest("Failed to publish: " & error)

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message",
      contentTopic = message.contentTopic, rln = not node.wakuRlnRelay.isNil()

    var publishFut = node.publish(some(pubsubTopic), message)
    if not await publishFut.withTimeout(futTimeout):
      return RestApiResponse.internalServerError("Failed to publish: timedout")

    var res = publishFut.read()

    if res.isErr():
      return RestApiResponse.badRequest("Failed to publish. " & res.error)

    return RestApiResponse.ok()
