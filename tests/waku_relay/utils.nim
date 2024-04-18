{.used.}

import
  std/[strutils, sequtils, tempfiles],
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  libp2p/switch,
  libp2p/protocols/pubsub/pubsub

from std/times import epochTime

import
  ../../../waku/
    [
      waku_relay,
      node/waku_node,
      node/peer_manager,
      waku_core,
      waku_node,
      waku_rln_relay,
    ],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync, futures],
  ../resources/payloads

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

proc setupRln*(node: WakuNode, identifier: uint) {.async.} =
  await node.mountRlnRelay(
    WakuRlnConfig(
      rlnRelayDynamic: false,
      rlnRelayCredIndex: some(identifier),
      rlnRelayTreePath: genTempPath("rln_tree", "wakunode_" & $identifier),
      rlnEpochSizeSec: 1,
    )
  )

proc setupRelayWithRln*(
    node: WakuNode, identifier: uint, pubsubTopics: seq[string]
) {.async.} =
  await node.mountRelay(pubsubTopics)
  await setupRln(node, identifier)

proc subscribeToContentTopicWithHandler*(
    node: WakuNode, contentTopic: string
): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == topic:
      completionFut.complete(true)

  node.subscribe((kind: ContentSub, topic: contentTopic), some(relayHandler))
  return completionFut

proc subscribeCompletionHandler*(node: WakuNode, pubsubTopic: string): Future[bool] =
  var completionFut = newFuture[bool]()
  proc relayHandler(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    if topic == pubsubTopic:
      completionFut.complete(true)

  node.subscribe((kind: PubsubSub, topic: pubsubTopic), some(relayHandler))
  return completionFut

proc sendRlnMessage*(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  var message = WakuMessage(payload: payload, contentTopic: contentTopic)
  doAssert(client.wakuRlnRelay.appendRLNProof(message, epochTime()).isOk())
  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted

proc sendRlnMessageWithInvalidProof*(
    client: WakuNode,
    pubsubTopic: string,
    contentTopic: string,
    completionFuture: Future[bool],
    payload: seq[byte] = "Hello".toBytes(),
): Future[bool] {.async.} =
  let
    extraBytes: seq[byte] = @[byte(1), 2, 3]
    rateLimitProofRes = client.wakuRlnRelay.groupManager.generateProof(
      concat(payload, extraBytes),
        # we add extra bytes to invalidate proof verification against original payload
      client.wakuRlnRelay.getCurrentEpoch(),
    )
    rateLimitProof = rateLimitProofRes.get().encode().buffer
    message =
      WakuMessage(payload: @payload, contentTopic: contentTopic, proof: rateLimitProof)

  discard await client.publish(some(pubsubTopic), message)
  let isCompleted = await completionFuture.withTimeout(FUTURE_TIMEOUT)
  return isCompleted
