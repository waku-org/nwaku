import results, options, chronos
import waku/[waku_node, waku_core, waku_lightpush]
import publisher_base

type V3Publisher* = ref object of PublisherBase

proc new*(T: typedesc[V3Publisher], wakuNode: WakuNode): V3Publisher =
  if isNil(wakuNode.wakuLightpushClient):
    wakuNode.mountLegacyLightPushClient()

  return V3Publisher(wakuNode: wakuNode)

method send*(
    self: V3Publisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  discard (
    await self.wakuNode.lightpushPublish(some(topic), message, some(servicePeer))
  ).valueOr:
    if error.code == NO_PEERS_TO_RELAY and
        error.desc != some("No peers for topic, skipping publish"):
      # TODO: We need better separation of errors happening on the client side or the server side.-
      return err("dial_failure")
    else:
      return err($error.code)
  return ok()
