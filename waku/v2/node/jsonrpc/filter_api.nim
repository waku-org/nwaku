{.push raises: [Defect].}

import
  std/[tables, sequtils],
  chronicles,
  json_rpc/rpcserver
import
  ../../protocol/waku_message,
  ../../protocol/waku_filter,
  ../../protocol/waku_filter/client,
  ../waku_node,
  ./jsonrpc_types

export jsonrpc_types

logScope:
  topics = "wakunode.rpc.filter"


const DefaultPubsubTopic: PubsubTopic = "/waku/2/default-waku/proto"
const futTimeout* = 5.seconds # Max time to wait for futures
const maxCache* = 30 # Max number of messages cached per topic TODO: make this configurable


proc installFilterApiHandlers*(node: WakuNode, rpcsrv: RpcServer, messageCache: MessageCache) =
  ## Filter API version 1 definitions

  rpcsrv.rpc("get_waku_v2_filter_v1_messages") do (contentTopic: ContentTopic) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a content topic since the
    ## last time this method was called
    ## TODO: ability to specify a return message limit
    debug "get_waku_v2_filter_v1_messages", contentTopic=contentTopic

    if not messageCache.hasKey(contentTopic):
      raise newException(ValueError, "Not subscribed to content topic: " & $contentTopic)

    let msgs = messageCache[contentTopic]
    # Clear cache before next call
    messageCache[contentTopic] = @[]
    return msgs
  

  rpcsrv.rpc("post_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    let
      pubsubTopic: string = topic.get(DefaultPubsubTopic)
      contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let pushHandler:FilterPushHandler = proc(pubsubTopic: string, msg: WakuMessage) {.gcsafe, closure.} =
        # Add message to current cache
        trace "WakuMessage received", msg=msg
        
        # Make a copy of msgs for this topic to modify
        var msgs = messageCache.getOrDefault(msg.contentTopic, @[])

        if msgs.len >= maxCache:
          # Message cache on this topic exceeds maximum. Delete oldest.
          # TODO: this may become a bottle neck if called as the norm rather than exception when adding messages. Performance profile needed.
          msgs.delete(0,0)

        msgs.add(msg)

        # Replace indexed entry with copy
        # TODO: max number of content topics could be limited in node
        messageCache[msg.contentTopic] = msgs 
  
    let subFut = node.subscribe(pubsubTopic, contentTopics, pushHandler)

    if not await subFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to subscribe to contentFilters")

    # Successfully subscribed to all content filters
    for cTopic in contentTopics:
      # Create message cache for each subscribed content topic
      messageCache[cTopic] = @[]
    
    return true


  rpcsrv.rpc("delete_waku_v2_filter_v1_subscription") do(contentFilters: seq[ContentFilter], topic: Option[string]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    let
      pubsubTopic: string = topic.get(DefaultPubsubTopic)
      contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let unsubFut = node.unsubscribe(pubsubTopic, contentTopics)

    if not await unsubFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to unsubscribe from contentFilters")
    
    # Successfully unsubscribed from all content filters
    for cTopic in contentTopics:
      # Remove message cache for each unsubscribed content topic
      messageCache.del(cTopic)

    return true
