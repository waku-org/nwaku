import chronos, results
import
  logos_delivery/kernel/
    [kernel, api/lightpush, base/topics/pubsub_topic, base/message, base/peers]
import publisher_base

type LegacyPublisher* = ref object of PublisherBase

proc new*(T: type LegacyPublisher, kernel: Kernel): T =
  if isNil(kernel.protocols.legacyLightPushClient):
    kernel.mountLegacyLightPushClient()

  return LegacyPublisher(kernel: kernel)

method send*(
    self: LegacyPublisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  # when error it must return original error desc due the text is used for distinction between error types in metrics.
  discard (
    await self.kernel.legacyLightpushPublish(Opt.some(topic), message, servicePeer)
  ).valueOr:
    return err(error)
  return ok()
