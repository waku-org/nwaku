when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver,
  eth/keys
import
  ../message,
  ../../message_cache,
  ../../waku/common/base64,
  ../../waku/waku_core

from std/times import getTime, toUnix

when defined(rln):
  import
    ../../../waku_rln_relay

logScope:
  topics = "waku node jsonrpc relay_api"


const futTimeout* = 5.seconds # Max time to wait for futures

## Waku Relay JSON-RPC API

proc installRelayApiHandlers*(
  server: RpcServer,
  subscriptionsTx: AsyncEventQueue[SubscriptionEvent],
  messageTx: AsyncEventQueue[(PubsubTopic, WakuMessage)],
  cache: MessageCache[string],
  ) =
  server.rpc("post_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    # Subscribe to all requested topics
    let newTopics = topics.filterIt(not cache.isSubscribed(it))

    for topic in newTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: PubsubSub, pubsubSub: topic))

    return true

  server.rpc("delete_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    let subscribedTopics = topics.filterIt(cache.isSubscribed(it))

    for topic in subscribedTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: PubsubUnsub, pubsubUnsub: topic))

    return true

  server.rpc("post_waku_v2_relay_v1_message") do (topic: PubsubTopic, msg: WakuMessageRPC) -> bool:
    ## Publishes a WakuMessage to a PubSub topic
    debug "post_waku_v2_relay_v1_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    var message = WakuMessage(
        payload: payloadRes.value,
        # TODO: Fail if the message doesn't have a content topic
        contentTopic: msg.contentTopic.get(DefaultContentTopic),
        version: msg.version.get(0'u32),
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )
    
    when defined(rln):
      if not node.wakuRlnRelay.isNil():
        let success = node.wakuRlnRelay.appendRLNProof(message, 
                                                      float64(getTime().toUnix()))
        if not success:
          raise newException(ValueError, "Failed to append RLN proof to message")

    # TODO wait for an answer. Would require AsyncChannel[T]
    messageTx.emit((topic, message))

    return true

  server.rpc("get_waku_v2_relay_v1_messages") do (topic: PubsubTopic) -> seq[WakuMessageRPC]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    return msgRes.value.map(toWakuMessageRPC)

  # Autosharding API

  server.rpc("post_waku_v2_relay_v1_auto_subscriptions") do (topics: seq[ContentTopic]) -> bool:
    ## Subscribes a node to a list of Content topics
    debug "post_waku_v2_relay_v1_auto_subscriptions"

    let newTopics = topics.filterIt(not cache.isSubscribed(it))

    # Subscribe to all requested topics
    for topic in newTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentSub, contentSub: topic))

    return true

  server.rpc("delete_waku_v2_relay_v1_auto_subscriptions") do (topics: seq[ContentTopic]) -> bool:
    ## Unsubscribes a node from a list of Content topics
    debug "delete_waku_v2_relay_v1_auto_subscriptions"

    let subscribedTopics = topics.filterIt(cache.isSubscribed(it))

    # Unsubscribe all handlers from requested topics
    for topic in subscribedTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentUnsub, contentUnsub: topic))

    return true

  server.rpc("post_waku_v2_relay_v1_auto_message") do (msg: WakuMessageRPC) -> bool:
    ## Publishes a WakuMessage to a Content topic
    debug "post_waku_v2_relay_v1_auto_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    if msg.contentTopic.isNone():
      raise newException(ValueError, "must contain content topic")

    var message = WakuMessage(
        payload: payloadRes.value,
        contentTopic: msg.contentTopic.get(),
        version: msg.version.get(0'u32),
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )
    
    when defined(rln):
      if not node.wakuRlnRelay.isNil():
        let success = node.wakuRlnRelay.appendRLNProof(message, 
                                                      float64(getTime().toUnix()))
        if not success:
          raise newException(ValueError, "Failed to append RLN proof to message")

    let pubsubTopicRes = getShard(message.contentTopic)
    if pubsubTopicRes.isErr():
      raise newException(ValueError, pubsubTopicRes.error)

    # TODO wait for an answer. Would require AsyncChannel[T]
    messageTx.emit((pubsubTopicRes.get(), message))

    return true

  server.rpc("get_waku_v2_relay_v1_auto_messages") do (topic: ContentTopic) -> seq[WakuMessageRPC]:
    ## Returns all WakuMessages received on a Content topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_auto_messages", topic=topic

    if not cache.isSubscribed(topic):
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    #TODO request/reponse via channel to communicate with cache. Would require AsyncChannel[T]
    let msgRes = cache.getMessages(topic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & topic)

    return msgRes.value.map(toWakuMessageRPC)
