{.push raises: [Exception, Defect].}

import
  std/[tables,sequtils],
  json_rpc/rpcserver,
  eth/[common, rlp, keys, p2p],
  ../../waku_types,
  ../wakunode2

const futTimeout = 5.seconds

proc installFilterApiHandlers*(node: WakuNode, rpcsrv: RpcServer) =
  ## Create a message cache indexed on content topic
  ## @TODO consider moving message cache elsewhere. Perhaps to node?
  var
    messageCache = initTable[ContentTopic, seq[WakuMessage]]()
  
  proc filterHandler(msg: WakuMessage) {.gcsafe, closure.} =
    debug "WakuMessage received", msg=msg
    # Add message to current cache
    # @TODO limit max content topics and messages
    messageCache.mgetOrPut(msg.contentTopic, @[]).add(msg)

  ## Filter API version 1 definitions
  
  rpcsrv.rpc("get_waku_v2_filter_v1_messages") do(contentTopic: ContentTopic) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a content topic since the
    ## last time this method was called
    ## @TODO ability to specify a return message limit
    debug "get_waku_v2_filter_v1_messages", contentTopic=contentTopic

    if messageCache.hasKey(contentTopic):
      let msgs = messageCache[contentTopic]
      # Clear cache before next call
      messageCache[contentTopic] = @[]
      return msgs
    else:
      # Not subscribed to this content topic
      raise newException(ValueError, "Not subscribed to content topic: " & $contentTopic)
  
  rpcsrv.rpc("post_waku_v2_filter_v1_subscription") do(contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    # Construct a filter request
    # @TODO use default PubSub topic if undefined
    let fReq = if topic.isSome: FilterRequest(topic: topic.get, contentFilters: contentFilters, subscribe: true) else: FilterRequest(contentFilters: contentFilters, subscribe: true)
    
    if (await node.subscribe(fReq, filterHandler).withTimeout(futTimeout)):
      # Successfully subscribed to all content filters
      
      for cTopic in concat(contentFilters.mapIt(it.topics)):
        # Create message cache for each subscribed content topic
        messageCache[cTopic] = @[]
      
      return true
    else:
      # Failed to subscribe to one or more content filters
      raise newException(ValueError, "Failed to subscribe to contentFilters " & repr(fReq))

  rpcsrv.rpc("delete_waku_v2_filter_v1_subscription") do(contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    # Construct a filter request
    # @TODO consider using default PubSub topic if undefined
    let fReq = if topic.isSome: FilterRequest(topic: topic.get, contentFilters: contentFilters, subscribe: false) else: FilterRequest(contentFilters: contentFilters, subscribe: false)

    if (await node.unsubscribe(fReq).withTimeout(futTimeout)):
      # Successfully unsubscribed from all content filters

      for cTopic in concat(contentFilters.mapIt(it.topics)):
        # Remove message cache for each unsubscribed content topic
        messageCache.del(cTopic)

      return true
    else:
      # Failed to unsubscribe from one or more content filters
      raise newException(ValueError, "Failed to unsubscribe from contentFilters " & repr(fReq))