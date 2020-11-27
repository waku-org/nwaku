import
  json_rpc/rpcserver,
  eth/[common, rlp, keys, p2p],
  ../../waku_types,  
  ../wakunode2

proc installRelayApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  const futTimeout = 5.seconds

  ## Relay API version 1 definitions

  rpcsrv.rpc("post_waku_v2_relay_v1_subscriptions") do(topics: seq[string]) -> bool:
    ## Subscribes a node to a list of PubSub topics
    debug "post_waku_v2_relay_v1_subscriptions"

    proc topicHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        debug "WakuMessage received", msg=msg, topic=topic
        # @TODO handle message
      else:
        debug "WakuMessage received but failed to decode", msg=msg, topic=topic
        # @TODO handle message decode failure
    
    var failedTopics: seq[string]

    # Subscribe to all requested topics
    for topic in topics:
      # If any topic fails to subscribe, add to list of failedTopics
      if not(await node.subscribe(topic, topicHandler).withTimeout(futTimeout)):
        failedTopics.add(topic)

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
      # If any topic fails to unsubscribe, add to list of failedTopics
      if not(await node.unsubscribeAll(topic).withTimeout(futTimeout)):
        failedTopics.add(topic)

    if (failedTopics.len() == 0):
      # Successfully unsubscribed from all requested topics
      return true
    else:
      # Failed to unsubscribe from one or more topics
      raise newException(ValueError, "Failed to unsubscribe from topics " & repr(failedTopics))
    
