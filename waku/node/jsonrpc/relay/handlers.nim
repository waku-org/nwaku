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
  ../../waku_node,
  ../../message_cache,
  ../message

from std/times import getTime
from std/times import toUnix

when defined(rln):
  import
    ../../../waku_rln_relay

logScope:
  topics = "waku node jsonrpc relay_api"


const futTimeout* = 5.seconds # Max time to wait for futures

type
  MessageCache* = message_cache.MessageCache[PubsubTopic]


## Waku Relay JSON-RPC API

proc installRelayApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =
  if node.wakuRelay.isNil():
    debug "waku relay protocol is nil. skipping json rpc api handlers installation"
    return

  let topicHandler = proc(topic: PubsubTopic, message: WakuMessage) {.async.} =
      cache.addMessage(topic, message)

  # The node may already be subscribed to some topics when Relay API handlers
  # are installed
  for topic in node.wakuRelay.subscribedTopics:
    node.subscribe(topic, topicHandler)
    cache.subscribe(topic)


  server.rpc("post_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    # Subscribe to all requested topics
    for topic in topics:
      if cache.isSubscribed(topic):
        continue

      cache.subscribe(topic)
      node.subscribe(topic, topicHandler)

    return true

  server.rpc("delete_waku_v2_relay_v1_subscriptions") do (topics: seq[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    for topic in topics:
      node.unsubscribe(topic)
      cache.unsubscribe(topic)

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

    let publishFut = node.publish(topic, message)

    if not await publishFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to publish to topic " & topic)

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


## Waku Relay Private JSON-RPC API (Whisper/Waku v1 compatibility)
## Support for the Relay Private API has been deprecated.
## This API existed for compatibility with the Waku v1/Whisper spec and encryption schemes.
## It is recommended to use the Relay API instead.
