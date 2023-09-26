when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver,
  eth/keys,
  nimcrypto/sysrand
import
  ../../../common/base64,
  ../../../waku_core,
  ../../../waku_relay,
  ../../../waku_rln_relay,
  ../../../waku_rln_relay/rln/wrappers,
  ../../../waku_node,
  ../../message_cache,
  ../../cache_handlers,
  ../message

from std/times import getTime
from std/times import toUnix


logScope:
  topics = "waku node jsonrpc relay_api"


const futTimeout* = 5.seconds # Max time to wait for futures

## Waku Relay JSON-RPC API

proc installRelayApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache[string]) =
  server.rpc("post_waku_v2_relay_v1_subscriptions") do (pubsubTopics: seq[PubsubTopic]) -> bool:
    if pubsubTopics.len == 0:
      raise newException(ValueError, "No pubsub topic provided")
    
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    # Subscribe to all requested topics
    let newTopics = pubsubTopics.filterIt(not cache.isSubscribed(it))

    for pubsubTopic in newTopics:
      if pubsubTopic == "":
        raise newException(ValueError, "Empty pubsub topic")

      cache.subscribe(pubsubTopic)
      node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(messageCacheHandler(cache)))

    return true

  server.rpc("delete_waku_v2_relay_v1_subscriptions") do (pubsubTopics: seq[PubsubTopic]) -> bool:
    if pubsubTopics.len == 0:
      raise newException(ValueError, "No pubsub topic provided")
    
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    let subscribedTopics = pubsubTopics.filterIt(cache.isSubscribed(it))

    for pubsubTopic in subscribedTopics:
      if pubsubTopic == "":
        raise newException(ValueError, "Empty pubsub topic")

      cache.unsubscribe(pubsubTopic)
      node.unsubscribe((kind: PubsubUnsub, topic: pubsubTopic))

    return true

  server.rpc("post_waku_v2_relay_v1_message") do (pubsubTopic: PubsubTopic, msg: WakuMessageRPC) -> bool:
    if pubsubTopic == "":
      raise newException(ValueError, "Empty pubsub topic")
    
    ## Publishes a WakuMessage to a PubSub topic
    debug "post_waku_v2_relay_v1_message", pubsubTopic=pubsubTopic

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    if msg.contentTopic.isNone():
      raise newException(ValueError, "message has no content topic")

    var message = WakuMessage(
        payload: payloadRes.value,
        contentTopic: msg.contentTopic.get(),
        version: msg.version.get(0'u32),
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )

    # ensure the node is subscribed to the pubsubTopic. otherwise it risks publishing
    # to a topic with no connected peers
    if pubsubTopic notin node.wakuRelay.subscribedTopics():
      raise newException(
        ValueError, "Failed to publish: Node not subscribed to pubsubTopic: " & pubsubTopic)

    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      # append the proof to the message
      let success = node.wakuRlnRelay.appendRLNProof(message,
                                                    float64(getTime().toUnix()))
      if not success:
        raise newException(ValueError, "Failed to publish: error appending RLN proof to message")
      # validate the message before sending it
      let result = node.wakuRlnRelay.validateMessage(message)
      if result == MessageValidationResult.Invalid:
        raise newException(ValueError, "Failed to publish: invalid RLN proof")
      elif result == MessageValidationResult.Spam:
        raise newException(ValueError, "Failed to publish: limit exceeded, try again later")
      elif result == MessageValidationResult.Valid:
        debug "RLN proof validated successfully", pubSubTopic=pubsubTopic
      else:
        raise newException(ValueError, "Failed to publish: unknown RLN proof validation result")

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message", pubSubTopic=pubsubTopic, rln=defined(rln)
    let publishFut = node.publish(some(pubsubTopic), message)
    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish: timed out")

    return true

  server.rpc("get_waku_v2_relay_v1_messages") do (pubsubTopic: PubsubTopic) -> seq[WakuMessageRPC]:
    if pubsubTopic == "":
      raise newException(ValueError, "Empty pubsub topic")
    
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_messages", topic=pubsubTopic

    let msgRes = cache.getMessages(pubsubTopic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to pubsub topic: " & pubsubTopic)

    return msgRes.value.map(toWakuMessageRPC)

  # Autosharding API

  server.rpc("post_waku_v2_relay_v1_auto_subscriptions") do (contentTopics: seq[ContentTopic]) -> bool:
    if contentTopics.len == 0:
      raise newException(ValueError, "No content topic provided")
    
    ## Subscribes a node to a list of Content topics
    debug "post_waku_v2_relay_v1_auto_subscriptions"

    let newTopics = contentTopics.filterIt(not cache.isSubscribed(it))

    # Subscribe to all requested topics
    for contentTopic in newTopics:
      if contentTopic == "":
        raise newException(ValueError, "Empty content topic")

      cache.subscribe(contentTopic)
      node.subscribe((kind: ContentSub, topic: contentTopic), some(autoMessageCacheHandler(cache)))

    return true

  server.rpc("delete_waku_v2_relay_v1_auto_subscriptions") do (contentTopics: seq[ContentTopic]) -> bool:
    if contentTopics.len == 0:
      raise newException(ValueError, "No content topic provided")
    
    ## Unsubscribes a node from a list of Content topics
    debug "delete_waku_v2_relay_v1_auto_subscriptions"

    let subscribedTopics = contentTopics.filterIt(cache.isSubscribed(it))

    # Unsubscribe all handlers from requested topics
    for contentTopic in subscribedTopics:
      if contentTopic == "":
        raise newException(ValueError, "Empty content topic")

      cache.unsubscribe(contentTopic)
      node.unsubscribe((kind: ContentUnsub, topic: contentTopic))

    return true

  server.rpc("post_waku_v2_relay_v1_auto_message") do (msg: WakuMessageRPC) -> bool:
    ## Publishes a WakuMessage to a Content topic
    debug "post_waku_v2_relay_v1_auto_message"

    let payloadRes = base64.decode(msg.payload)
    if payloadRes.isErr():
      raise newException(ValueError, "invalid payload format: " & payloadRes.error)

    if msg.contentTopic.isNone():
      raise newException(ValueError, "message has no content topic")

    var message = WakuMessage(
        payload: payloadRes.value,
        contentTopic: msg.contentTopic.get(),
        version: msg.version.get(0'u32),
        timestamp: msg.timestamp.get(Timestamp(0)),
        ephemeral: msg.ephemeral.get(false)
      )
    
    # if RLN is mounted, append the proof to the message
    if not node.wakuRlnRelay.isNil():
      # append the proof to the message
      let success = node.wakuRlnRelay.appendRLNProof(message,
                                                    float64(getTime().toUnix()))
      if not success:
        raise newException(ValueError, "Failed to publish: error appending RLN proof to message")
      # validate the message before sending it
      let result = node.wakuRlnRelay.validateMessage(message)
      if result == MessageValidationResult.Invalid:
        raise newException(ValueError, "Failed to publish: invalid RLN proof")
      elif result == MessageValidationResult.Spam:
        raise newException(ValueError, "Failed to publish: limit exceeded, try again later")
      elif result == MessageValidationResult.Valid:
        debug "RLN proof validated successfully", contentTopic=message.contentTopic
      else:
        raise newException(ValueError, "Failed to publish: unknown RLN proof validation result")

    # if we reach here its either a non-RLN message or a RLN message with a valid proof
    debug "Publishing message", contentTopic=message.contentTopic, rln=defined(rln)
    let publishFut = node.publish(none(PubsubTopic), message)
    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish: timed out")

    return true

  server.rpc("get_waku_v2_relay_v1_auto_messages") do (contentTopic: ContentTopic) -> seq[WakuMessageRPC]:
    if contentTopic == "":
        raise newException(ValueError, "Empty content topic")
    
    ## Returns all WakuMessages received on a Content topic since the
    ## last time this method was called
    debug "get_waku_v2_relay_v1_auto_messages", topic=contentTopic

    let msgRes = cache.getMessages(contentTopic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to content topic: " & contentTopic)

    return msgRes.value.map(toWakuMessageRPC)