## Waku layer API — filter (light client) operations.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/waku/waku
import
  logos_delivery/waku/[
    waku_core,
    waku_core/subscription/push_handler,
    node/waku_node,
    node/waku_node/filter,
    node/peer_manager,
    waku_filter_v2/client,
    waku_filter_v2/common,
  ]

const FilterOpTimeout = 5.seconds

proc filterSubscribe*(
    self: Kernel,
    pubsubTopic: PubsubTopic,
    contentTopics: seq[ContentTopic],
    pushHandler: FilterPushHandler,
): Future[Result[bool, string]] {.async.} =
  ## Registers `pushHandler` for incoming filtered messages, selects a filter
  ## service peer, and subscribes.
  try:
    if self.protocols.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    self.protocols.wakuFilterClient.registerPushHandler(pushHandler)

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when subscribing")

    let subFut = self.filterSubscribe(Opt.some(pubsubTopic), contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      return err("filter subscription timed out")
    subFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribe*(
    self: Kernel, pubsubTopic: PubsubTopic, contentTopics: seq[ContentTopic]
): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes the given content topics.
  try:
    if self.protocols.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when unsubscribing")

    let unsubFut =
      self.filterUnsubscribe(Opt.some(pubsubTopic), contentTopics, peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribeAll*(self: Kernel): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes from everything.
  try:
    if self.protocols.wakuFilterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return
        err("could not find peer with WakuFilterSubscribeCodec when unsubscribing all")

    let unsubFut = self.filterUnsubscribeAll(peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription all timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)
