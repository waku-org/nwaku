import results, chronos
import
  logos_delivery/kernel/[
    kernel,
    api/lightpush,
    protocols/topics/pubsub_topic,
    protocols/message,
    peer_manager/peers,
    protocols/lightpush/common,
    protocols/lightpush/rpc,
  ]
import publisher_base

type V3Publisher* = ref object of PublisherBase

proc new*(T: type V3Publisher, kernel: Kernel): T =
  if isNil(kernel.protocols.lightPushClient):
    kernel.mountLightPushClient()

  return V3Publisher(kernel: kernel)

method send*(
    self: V3Publisher,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.async.} =
  # when error it must return original error desc due the text is used for distinction between error types in metrics.
  discard (
    await self.kernel.lightpushPublish(Opt.some(topic), message, Opt.some(servicePeer))
  ).valueOr:
    if error.code == LightPushErrorCode.NO_PEERS_TO_RELAY and
        error.desc != Opt.some("No peers for topic, skipping publish"):
      # TODO: We need better separation of errors happening on the client side or the server side.-
      return err("dial_failure")
    else:
      return err($error.code)
  return ok()
