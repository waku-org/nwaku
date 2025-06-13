import chronicles, chronos, results
import waku/[waku_node, waku_core]

type PublisherBase* = ref object of RootObj
  wakuNode*: WakuNode

method send*(
    self: PublisherBase,
    topic: PubsubTopic,
    message: WakuMessage,
    servicePeer: RemotePeerInfo,
): Future[Result[void, string]] {.base, async.} =
  raiseAssert "Not implemented!"
