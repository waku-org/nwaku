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
  ../../../waku_filter,
  ../../../waku_filter/rpc,
  ../../../waku_filter/client,
  ../../../waku_node,
  ../../../node/peer_manager,
  ../../message_cache
  


logScope:
  topics = "waku node jsonrpc filter_api"


const futTimeout* = 5.seconds # Max time to wait for futures

proc installFilterApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =

  server.rpc("post_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], pubsubTopic: Option[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    let peerOpt = node.peerManager.selectPeer(WakuLegacyFilterCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote filter peers")

    let contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let handler: FilterPushHandler = proc(pubsubTopic: PubsubTopic, msg: WakuMessage, msgId: seq[byte]) {.async, gcsafe, closure.} =
        cache.addMessage(pubsubTopic, msg)

    let subFut = node.legacyFilterSubscribe(pubsubTopic, contentTopics, handler, peerOpt.get())
    if not await subFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to subscribe to contentFilters")

    # Successfully subscribed to all content filters
    for cTopic in contentTopics:
      cache.contentSubscribe(cTopic)

    return true

  server.rpc("delete_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], pubsubTopic: Option[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    let contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let peerOpt = node.peerManager.selectPeer(WakuLegacyFilterCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote filter peers")

    let unsubFut = node.legacyFilterUnsubscribe(pubsubTopic, contentTopics, peerOpt.get())
    if not await unsubFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to unsubscribe from contentFilters")

    for cTopic in contentTopics:
      cache.contentUnsubscribe(cTopic)

    return true

  server.rpc("get_waku_v2_filter_v1_messages") do (contentTopic: ContentTopic) -> seq[WakuMessage]:
    ## Returns all WakuMessages received on a content topic since the
    ## last time this method was called
    debug "get_waku_v2_filter_v1_messages", contentTopic=contentTopic

    if not cache.isContentSubscribed(contentTopic):
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    let msgRes = cache.getMessages(contentTopic, clear=true)
    if msgRes.isErr():
      raise newException(ValueError, "Not subscribed to topic: " & contentTopic)

    return msgRes.value
