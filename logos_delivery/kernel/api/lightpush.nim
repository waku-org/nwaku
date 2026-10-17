## Waku layer API — lightpush (light client publish) operations.
{.push raises: [].}

import results, chronos, chronicles

import logos_delivery/kernel/kernel_lifecycle
import
  logos_delivery/kernel/[core/topics/pubsub_topic, core/message, protocols/codecs, node/peer_manager/peer_manager, protocols/lightpush_legacy/client]

proc lightpushPublish*(
    self: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[Result[string, string]] {.async.} =
  ## Selects a lightpush service peer and publishes; returns the message hash.
  try:
    if self.protocols.legacyLightPushClient.isNil():
      return err("wakuLegacyLightpushClient is not mounted")

    let remotePeer = self.peerManager.selectPeer(WakuLightPushCodec).valueOr:
      return err("failed to lightpublish message, no suitable remote peers")

    let msgHashHex = (
      await self.protocols.legacyLightPushClient.publish(
        pubsubTopic, message, remotePeer
      )
    ).valueOr:
      return err($error)

    return ok(msgHashHex)
  except CatchableError as e:
    return err(e.msg)
