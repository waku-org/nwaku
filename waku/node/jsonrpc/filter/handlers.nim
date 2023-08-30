when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver
import
  ../../../waku_core,
  ../../../waku_filter/rpc,
  ../../message_cache,
  ../../peer_manager


logScope:
  topics = "waku node jsonrpc filter_api"


const futTimeout* = 5.seconds # Max time to wait for futures

proc installFilterApiHandlers*(
  server: RpcServer,
  subscriptionsTx: AsyncEventQueue[SubscriptionEvent],
  cache: MessageCache[string],
  ) =

  server.rpc("post_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], pubsubTopic: Option[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    let contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let newTopics = contentTopics.filterIt(not cache.isSubscribed(it))

    for topic in newTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentSub, contentSub: topic))

    return true

  server.rpc("delete_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], pubsubTopic: Option[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    let contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let subscribedTopics = contentTopics.filterIt(cache.isSubscribed(it))

    for topic in subscribedTopics:
      subscriptionsTx.emit(SubscriptionEvent(kind: ContentUnsub, contentUnsub: topic))

    return true

  server.rpc("get_waku_v2_filter_v1_messages") do (contentTopic: ContentTopic) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a content topic since the
    ## last time this method was called
    debug "get_waku_v2_filter_v1_messages", contentTopic=contentTopic

    if not cache.isSubscribed(contentTopic):
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    let msgRes = cache.getMessages(contentTopic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    return msgRes.value
