{.push raises: [Exception, Defect].}

import
  std/[tables,sequtils],
  json_rpc/rpcserver,
  libp2p/protocols/pubsub/pubsub,
  eth/[common, rlp, keys, p2p],
  ../wakunode2,
  ./jsonrpc_types, ./jsonrpc_utils,
  ../../protocol/waku_message

export jsonrpc_types

logScope:
  topics = "relay api"

const futTimeout* = 5.seconds # Max time to wait for futures
const maxCache* = 100 # Max number of messages cached per topic @TODO make this configurable

proc installRelayApiHandlers*(node: WakuNode, rpcsrv: RpcServer, topicCache: TopicCache) =
  
  proc topicHandler(topic: string, data: seq[byte]) {.async.} =
    trace "Topic handler triggered", topic=topic
    let msg = WakuMessage.init(data)
    if msg.isOk():
      # Add message to current cache
      trace "WakuMessage received", msg=msg, topic=topic
          
      # Make a copy of msgs for this topic to modify
      var msgs = topicCache.getOrDefault(topic, @[])

      if msgs.len >= maxCache:
        # Message cache on this topic exceeds maximum. Delete oldest.
        # @TODO this may become a bottle neck if called as the norm rather than exception when adding messages. Performance profile needed.
        msgs.delete(0,0)
      msgs.add(msg[])

      # Replace indexed entry with copy
      # @TODO max number of topics could be limited in node
      topicCache[topic] = msgs
    else:
      debug "WakuMessage received but failed to decode", msg=msg, topic=topic
      # @TODO handle message decode failure
  
  ## Node may already be subscribed to some topics when Relay API handlers are installed. Let's add these
  for topic in PubSub(node.wakuRelay).topics.keys:
    debug "Adding API topic handler for existing subscription", topic=topic

    node.subscribe(topic, topicHandler)      
    
    # Create message cache for this topic
    debug "MessageCache for topic", topic=topic
    topicCache[topic] = @[]

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

    # Subscribe to all requested topics
    for topic in topics:
      # Only subscribe to topics for which we have no subscribed topic handlers yet
      if not topicCache.hasKey(topic):
        node.subscribe(topic, topicHandler)
        # Create message cache for this topic
        trace "MessageCache for topic", topic=topic
        topicCache[topic] = @[]
    
    # Successfully subscribed to all requested topics
    return true

  rpcsrv.rpc("delete_waku_v2_relay_v1_subscriptions") do(topics: seq[string]) -> bool:
    ## Unsubscribes a node from a list of PubSub topics
    debug "delete_waku_v2_relay_v1_subscriptions"

    # Unsubscribe all handlers from requested topics
    for topic in topics:
      node.unsubscribeAll(topic)
      # Remove message cache for topic
      topicCache.del(topic)

    # Successfully unsubscribed from all requested topics
    return true 
