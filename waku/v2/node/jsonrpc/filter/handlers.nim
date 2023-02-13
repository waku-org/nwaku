when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/sequtils,
  chronicles,
  json_rpc/rpcserver
import
  ../../../../waku/v2/protocol/waku_message,
  ../../../../waku/v2/protocol/waku_filter,
  ../../../../waku/v2/protocol/waku_filter/rpc,
  ../../../../waku/v2/protocol/waku_filter/client,
  ../../../../waku/v2/node/message_cache,
  ../../../../waku/v2/node/peer_manager,
  ../../../../waku/v2/node/waku_node


logScope:
  topics = "waku node jsonrpc filter_api"


const DefaultPubsubTopic: PubsubTopic = "/waku/2/default-waku/proto"

const futTimeout* = 5.seconds # Max time to wait for futures


type
  MessageCache* = message_cache.MessageCache[ContentTopic]


proc installFilterApiHandlers*(node: WakuNode, server: RpcServer, cache: MessageCache) =

  server.rpc("post_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], topic: Option[PubsubTopic]) -> bool:
    ## Subscribes a node to a list of content filters
    debug "post_waku_v2_filter_v1_subscription"

    let peerOpt = node.peerManager.selectPeer(WakuFilterCodec)
    if peerOpt.isNone():
      raise newException(ValueError, "no suitable remote filter peers")

    let
      pubsubTopic: PubsubTopic = topic.get(DefaultPubsubTopic)
      contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let handler: FilterPushHandler = proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.gcsafe, closure.} =
        cache.addMessage(msg.contentTopic, msg)

    let subFut = node.filterSubscribe(pubsubTopic, contentTopics, handler, peerOpt.get())
    if not await subFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to subscribe to contentFilters")

    # Successfully subscribed to all content filters
    for cTopic in contentTopics:
      cache.subscribe(cTopic)

    return true

  server.rpc("delete_waku_v2_filter_v1_subscription") do (contentFilters: seq[ContentFilter], topic: Option[PubsubTopic]) -> bool:
    ## Unsubscribes a node from a list of content filters
    debug "delete_waku_v2_filter_v1_subscription"

    let
      pubsubTopic: PubsubTopic = topic.get(DefaultPubsubTopic)
      contentTopics: seq[ContentTopic] = contentFilters.mapIt(it.contentTopic)

    let unsubFut = node.unsubscribe(pubsubTopic, contentTopics)
    if not await unsubFut.withTimeout(futTimeout):
      raise newException(ValueError, "Failed to unsubscribe from contentFilters")

    for cTopic in contentTopics:
      cache.unsubscribe(cTopic)

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
