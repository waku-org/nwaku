{.push raises: [].}

import results, chronos, libp2p/peerid
import
  logos_delivery/kernel/
    [protocols/topics/pubsub_topic, protocols/topics/pubsub_topic, protocols/message],
  logos_delivery/kernel/protocols/codecs

from logos_delivery/kernel/protocols/codecs import WakuLegacyLightPushCodec
export WakuLegacyLightPushCodec

type WakuLightPushResult*[T] = Result[T, string]

type PushMessageHandler* = proc(
  pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async.}

const TooManyRequestsMessage* = "TOO_MANY_REQUESTS"
