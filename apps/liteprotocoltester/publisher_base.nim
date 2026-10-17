import chronos, results
import
  logos_delivery/kernel/[kernel, core/topics/pubsub_topic, core/message, core/peers]

type PublisherBase* = ref object of RootObj
  kernel*: Kernel

method send*(
    self: PublisherBase,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.base, async.} =
  discard
  # when error it must return original error desc due the text is used for distinction between error types in metrics.
