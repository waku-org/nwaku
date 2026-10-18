{.push raises: [].}

import results, chronos, libp2p/peerid
import logos_delivery/kernel/[common/topics/pubsub_topic, common/message, common/codecs]
from logos_delivery/kernel/common/codecs import WakuLegacyLightPushCodec
export WakuLegacyLightPushCodec

type WakuLightPushResult*[T] = Result[T, string]

type PushMessageHandler* = proc(
  pubsubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async.}

const TooManyRequestsMessage* = "TOO_MANY_REQUESTS"
