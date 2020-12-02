{.push raises: [Exception, Defect].}

import
  std/[tables,sequtils],
  json_rpc/rpcserver,
  libp2p/protocols/pubsub/pubsub,
  eth/[common, rlp, keys, p2p],
  ../../waku_types,  
  ../wakunode2,
  ./jsonrpc_types, ./jsonrpc_utils

const futTimeout = 5.seconds

proc installRelayApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  ## Create a per-topic message cache
  var
    topicCache = initTable[string, seq[WakuMessage]]()
  
  proc topicHandler(topic: string, data: seq[byte]) {.async.} =
    debug "Topic handler triggered"
    let msg = WakuMessage.init(data)
    if msg.isOk():
      debug "WakuMessage received", msg=msg, topic=topic
      # Add message to current cache
      # @TODO limit max topics and messages
      topicCache.mgetOrPut(topic, @[]).add(msg[])
    else:
      debug "WakuMessage received but failed to decode", msg=msg, topic=topic
      # @TODO handle message decode failure

  ## Relay API version 1 definitions
  
  rpcsrv.rpc("post_waku_v2_relay_v1_message") do(topic: string, message: WakuRelayMessage) -> bool:
    ## Publishes a WakuMessage to a PubSub topic
    debug "post_waku_v2_relay_v1_message"

    if (await node.publish(topic, message.toWakuMessage(version = 0)).withTimeout(futTimeout)):
      # Successfully published message
      return true
    else:
      # Failed to publish message to topic
      raise newException(ValueError, "Failed to publish to topic " & topic)

  rpcsrv.rpc("get_waku_v2_relay_v1_messages") do(topic: string) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a PubSub topic since the
    ## last time this method was called
    ## @TODO ability to specify a return message limit
    debug "get_waku_v2_relay_v1_messages", topic=topic

    if topicCache.hasKey(topic):
      let msgs = topicCache[topic]
      # Clear cache before next call
      topicCache[topic] = @[]
      return msgs
    else:
      # Not subscribed to this topic
      raise newException(ValueError, "Not subscribed to topic: " & topic)

  rpcsrv.rpc("post_waku_v2_relay_v1_subscriptions") do(topics: seq[string]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"
  
    var failedTopics: seq[string]

    # Subscribe to all requested topics
    for topic in topics:
      if not(await node.subscribe(topic, topicHandler).withTimeout(futTimeout)):
        # If any topic fails to subscribe, add to list of failedTopics
        failedTopics.add(topic)
      else:
        # Create message cache for this topic
        debug "MessageCache for topic", topic=topic
        topicCache[topic] = @[]

    if (failedTopics.len() == 0):
      # Successfully subscribed to all requested topics
      return true
    else:
      # Failed to subscribe to one or more topics
      raise newException(ValueError, "Failed to subscribe to topics " & repr(failedTopics))

  rpcsrv.rpc("delete_waku_v2_relay_v1_subscriptions") do(topics: seq[string]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"
   
    var failedTopics: seq[string]

    # Unsubscribe all handlers from requested topics
    for topic in topics:
      if not(await node.unsubscribeAll(topic).withTimeout(futTimeout)):
        # If any topic fails to unsubscribe, add to list of failedTopics
        failedTopics.add(topic)
      else:
        # Remove message cache for topic
        topicCache.del(topic)

    if (failedTopics.len() == 0):
      # Successfully unsubscribed from all requested topics
      return true
    else:
      # Failed to unsubscribe from one or more topics
      raise newException(ValueError, "Failed to unsubscribe from topics " & repr(failedTopics))
    
