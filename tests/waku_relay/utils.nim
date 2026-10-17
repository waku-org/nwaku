{.used.}

import
  results,
  std/[strutils],
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

import
  logos_delivery/kernel/[
    protocols/relay/protocol,
    kernel,
    node/peer_manager/peer_manager,
    core/topics,
    core/topics/pubsub_topic,
    core/message,
    protocols/codecs,
    kernel,
    api/relay,
  ],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/wakucore

proc noopRawHandler*(): WakuRelayHandler =
  var handler: WakuRelayHandler
  handler = proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    discard
  handler

proc newTestWakuRelay*(switch = newTestSwitch()): Future[WakuRelay] {.async.} =
  let proto = WakuRelay.new(switch).tryGet()

  let protocolMatcher = proc(proto: string): bool {.gcsafe.} =
    return proto.startsWith(WakuRelayCodec)

  switch.mount(proto, protocolMatcher)

  return proto

proc subscribeToContentTopicWithHandler*(
    node: Kernel, contentTopic: string
): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    completionFut.complete(true)

  (node.subscribe((kind: ContentSub, topic: contentTopic), relayHandler)).isOkOr:
    raiseAssert "Failed to subscribe to content topic " & contentTopic & ": " & error
  return completionFut

proc subscribeCompletionHandler*(node: Kernel, pubsubTopic: string): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == pubsubTopic:
      completionFut.complete(true)

  (node.subscribe((kind: PubsubSub, topic: pubsubTopic), relayHandler)).isOkOr:
    error "Failed to subscribe to pubsub topic", error
    completionFut.complete(false)
  return completionFut
