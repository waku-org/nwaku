## Waku layer API — topic construction.
{.push raises: [].}

import std/strformat
import results, chronos

import logos_delivery/kernel/kernel_lifecycle
import logos_delivery/kernel/core/[ topics/content_topic, topics/pubsub_topic, topics/content_topic, topics/pubsub_topic]

proc buildContentTopic*(
    self: Kernel, appName: string, appVersion: uint32, name: string, encoding: string
): Future[Result[ContentTopic, string]] {.async.} =
  try:
    return ok(ContentTopic(fmt"/{appName}/{appVersion}/{name}/{encoding}"))
  except CatchableError as e:
    return err(e.msg)

proc buildPubsubTopic*(
    self: Kernel, topicName: string
): Future[Result[PubsubTopic, string]] {.async.} =
  try:
    return ok(PubsubTopic(fmt"/waku/2/{topicName}"))
  except CatchableError as e:
    return err(e.msg)

proc defaultPubsubTopic*(self: Kernel): Future[Result[PubsubTopic, string]] {.async.} =
  return ok(DefaultPubsubTopic)
