when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sets, sequtils],
  stew/byteutils,
  chronicles,
  json_serialization,
  json_serialization/std/options,
  presto/[route, client, common]
import 
  ../../waku_node,
  ../serdes,
  ../utils,
  ./api_types, 
  ./topic_cache

logScope: 
  topics = "waku node rest relay_api"


##### Topic cache

const futTimeout* = 5.seconds # Max time to wait for futures


#### Request handlers

const ROUTE_RELAY_SUBSCRIPTIONSV1* = "/relay/v1/subscriptions"

proc installRelayPostSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, topicCache: TopicCache) =

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
      if topicCache.isSubscribed(string(topic)):
        # Only subscribe to topics for which we have no subscribed topic handlers yet
        continue

      topicCache.subscribe(string(topic))
      node.subscribe(string(topic), topicCache.messageHandler())

    return RestApiResponse.ok()


proc installRelayDeleteSubscriptionsV1Handler*(router: var RestRouter, node: WakuNode, topicCache: TopicCache) =
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
      topicCache.unsubscribe(string(topic))

    # Successfully unsubscribed from all requested topics
    return RestApiResponse.ok() 


const ROUTE_RELAY_MESSAGESV1* = "/relay/v1/messages/{topic}"

proc installRelayGetMessagesV1Handler*(router: var RestRouter, node: WakuNode, topicCache: TopicCache) =
  router.api(MethodGet, ROUTE_RELAY_MESSAGESV1) do (topic: string) -> RestApiResponse: 
    # ## Returns all WakuMessages received on a PubSub topic since the
    # ## last time this method was called
    # ## TODO: ability to specify a return message limit
    # debug "get_waku_v2_relay_v1_messages", topic=topic

    if topic.isErr():
      return RestApiResponse.badRequest()
    let pubSubTopic = topic.get()

    let messages = topicCache.getMessages(pubSubTopic, clear=true)
    if messages.isErr():
      debug "Not subscribed to topic", topic=pubSubTopic
      return RestApiResponse.notFound() 
    
    let data = RelayGetMessagesResponse(messages.get().map(toRelayWakuMessage))
    let resp = RestApiResponse.jsonResponse(data, status=Http200)
    if resp.isErr():
      debug "An error ocurred while building the json respose", error=resp.error()
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


proc installRelayApiHandlers*(router: var RestRouter, node: WakuNode, topicCache: TopicCache) =
  installRelayGetMessagesV1Handler(router, node, topicCache)
  installRelayPostMessagesV1Handler(router, node)
  installRelayPostSubscriptionsV1Handler(router, node, topicCache)
  installRelayDeleteSubscriptionsV1Handler(router, node, topicCache)


#### Client

proc encodeBytes*(value: seq[PubSubTopicString],
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")
  
  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

proc decodeBytes*(t: typedesc[string], value: openarray[byte],
                  contentType: Opt[ContentTypeData]): RestResult[string] =
  if MediaType.init($contentType) != MIMETYPE_TEXT:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")
  
  var res: string
  if len(value) > 0:
    res = newString(len(value))
    copyMem(addr res[0], unsafeAddr value[0], len(value))
  return ok(res)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayPostSubscriptionsV1*(body: RelayPostSubscriptionsRequest): RestResponse[string] {.rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodPost.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayDeleteSubscriptionsV1*(body: RelayDeleteSubscriptionsRequest): RestResponse[string] {.rest, endpoint: "/relay/v1/subscriptions", meth: HttpMethod.MethodDelete.}


proc decodeBytes*(t: typedesc[RelayGetMessagesResponse], data: openArray[byte], contentType: Opt[ContentTypeData]): RestResult[RelayGetMessagesResponse] =
  if MediaType.init($contentType) != MIMETYPE_JSON:
    error "Unsupported respose contentType value", contentType = contentType
    return err("Unsupported response contentType")
  
  let decoded = ?decodeFromJsonBytes(RelayGetMessagesResponse, data)
  return ok(decoded)

proc encodeBytes*(value: RelayPostMessagesRequest,
                  contentType: string): RestResult[seq[byte]] =
  if MediaType.init(contentType) != MIMETYPE_JSON:
    error "Unsupported contentType value", contentType = contentType
    return err("Unsupported contentType")
  
  let encoded = ?encodeIntoJsonBytes(value)
  return ok(encoded)

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayGetMessagesV1*(topic: string): RestResponse[RelayGetMessagesResponse] {.rest, endpoint: "/relay/v1/messages/{topic}", meth: HttpMethod.MethodGet.}

# TODO: Check how we can use a constant to set the method endpoint (improve "rest" pragma under nim-presto)
proc relayPostMessagesV1*(topic: string, body: RelayPostMessagesRequest): RestResponse[string] {.rest, endpoint: "/relay/v1/messages/{topic}", meth: HttpMethod.MethodPost.}