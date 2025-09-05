import options, std/[strutils, sequtils]
import chronicles, chronos, results, ffi
import
  ../../../../waku/waku_filter_v2/client,
  ../../../../waku/waku_core/message/message,
  ../../../../waku/factory/waku,
  ../../../../waku/waku_filter_v2/common,
  ../../../../waku/waku_core/subscription/push_handler,
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/node/waku_node,
  ../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../waku/waku_core/topics/content_topic

const FilterOpTimeout = 5.seconds

proc checkFilterClientMounted(waku: ptr Waku): Result[string, string] =
  if waku.node.wakuFilterClient.isNil():
    let errorMsg = "wakuFilterClient is not mounted"
    error "fail filter process", error = errorMsg
    return err(errorMsg)
  return ok("")

registerReqFFI(FilterSubscribeReq, waku: ptr Waku):
  proc(
      pubSubTopic: cstring,
      contentTopics: cstring,
      filterPushEventCallback: FilterPushHandler,
  ): Future[Result[string, string]] {.async.} =
    checkFilterClientMounted(waku).isOkOr:
      return err($error)

    waku.node.wakuFilterClient.registerPushHandler(filterPushEventCallback)

    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when subscribing"
      error "fail filter subscribe", error = errorMsg
      return err(errorMsg)

    let subFut = waku.node.filterSubscribe(
      some(PubsubTopic($pubsubTopic)),
      ($contentTopics).split(",").mapIt(ContentTopic(it)),
      peer,
    )
    if not await subFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter subscription timed out"
      error "fail filter unsubscribe", error = errorMsg

      return err(errorMsg)

    return ok("")

registerReqFFI(FilterUnsubscribeReq, waku: ptr Waku):
  proc(
      pubSubTopic: cstring, contentTopics: cstring
  ): Future[Result[string, string]] {.async.} =
    checkFilterClientMounted(waku).isOkOr:
      return err($error)

    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when unsubscribing"
      error "fail filter process", error = errorMsg
      return err(errorMsg)

    let subFut = waku.node.filterUnsubscribe(
      some(PubsubTopic($pubsubTopic)),
      ($contentTopics).split(",").mapIt(ContentTopic(it)),
      peer,
    )
    if not await subFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter un-subscription timed out"
      error "fail filter unsubscribe", error = errorMsg
      return err(errorMsg)
    return ok("")

registerReqFFI(FilterUnsubscribeAllReq, waku: ptr Waku):
  proc(): Future[Result[string, string]] {.async.} =
    checkFilterClientMounted(waku).isOkOr:
      return err($error)

    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when unsubscribing all"
      error "fail filter unsubscribe all", error = errorMsg
      return err(errorMsg)

    let unsubFut = waku.node.filterUnsubscribeAll(peer)

    if not await unsubFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter un-subscription all timed out"
      error "fail filter unsubscribe all", error = errorMsg

      return err(errorMsg)
    return ok("")
