import chronos, results, options
import waku/[waku_node, waku_core]
import publisher_base

type LegacyPublisher* = ref object of PublisherBase

proc new*(T: typedesc[LegacyPublisher], wakuNode: WakuNode): LegacyPublisher =
  if isNil(wakuNode.wakuLightpushClient):
    wakuNode.mountLegacyLightPushClient()

  result = LegacyPublisher(wakuNode: wakuNode)

method send*(
    self: LegacyPublisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  discard (
    await self.wakuNode.legacyLightpushPublish(some(topic), message, servicePeer)
  ).valueOr:
    return err(error)
  return ok()
