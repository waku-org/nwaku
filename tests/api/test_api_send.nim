{.used.}

import results, std/[os, sequtils, strutils, sets, tempfiles]
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo], metrics
import brokers/broker_context
import
  ../testlib/[
    common, futures, wakucore, wakunode, wakunodeconf, testasync, short_intervals,
    rest_requests, rest_service,
  ]
import ../waku_archive/archive_utils
import
  logos_delivery,
  logos_delivery/waku/[
    kernel,
    waku_core,
    waku_relay/protocol,
    waku_lightpush/common,
    waku_lightpush/rpc,
    waku_lightpush/protocol_metrics,
    waku_archive,
    waku_archive/archive_metrics,
    common/base64,
  ],
  rest/server,
  rest/client,
  rest/kernel_api/relay/client as relay_rest_client
import logos_delivery/waku/factory/waku_conf
import logos_delivery/waku/api/subscriptions
import tools/confutils/cli_args
import logos_delivery/api/conf/messaging_conf
import logos_delivery/api/events/messaging_client_events
import logos_delivery/api/messaging_client_api
import logos_delivery/messaging/delivery_service/send_service

type SendEventOutcome {.pure.} = enum
  Sent
  Propagated
  Error

type SendEventListenerManager = ref object
  brokerCtx: BrokerContext
  sentListener: MessageSentEventListener
  errorListener: MessageErrorEventListener
  propagatedListener: MessagePropagatedEventListener
  sentFuture: Future[void]
  errorFuture: Future[void]
  propagatedFuture: Future[void]
  sentCount: int
  errorCount: int
  propagatedCount: int
  sentRequestIds: seq[RequestId]
  errorRequestIds: seq[RequestId]
  errorDescs: seq[string]
  propagatedRequestIds: seq[RequestId]

proc newSendEventListenerManager(brokerCtx: BrokerContext): SendEventListenerManager =
  let manager = SendEventListenerManager(brokerCtx: brokerCtx)
  manager.sentFuture = newFuture[void]("sentEvent")
  manager.errorFuture = newFuture[void]("errorEvent")
  manager.propagatedFuture = newFuture[void]("propagatedEvent")

  manager.sentListener = MessageSentEvent.listen(
    brokerCtx,
    proc(event: MessageSentEvent) {.async: (raises: []).} =
      inc manager.sentCount
      manager.sentRequestIds.add(event.requestId)
      echo "SENT EVENT TRIGGERED (#",
        manager.sentCount, "): requestId=", event.requestId
      if not manager.sentFuture.finished():
        manager.sentFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  manager.errorListener = MessageErrorEvent.listen(
    brokerCtx,
    proc(event: MessageErrorEvent) {.async: (raises: []).} =
      inc manager.errorCount
      manager.errorRequestIds.add(event.requestId)
      manager.errorDescs.add(event.error)
      echo "ERROR EVENT TRIGGERED (#", manager.errorCount, "): ", event.error
      if not manager.errorFuture.finished():
        manager.errorFuture.fail(
          newException(CatchableError, "Error event triggered: " & event.error)
        )
    ,
  ).valueOr:
    raiseAssert error

  manager.propagatedListener = MessagePropagatedEvent.listen(
    brokerCtx,
    proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
      inc manager.propagatedCount
      manager.propagatedRequestIds.add(event.requestId)
      echo "PROPAGATED EVENT TRIGGERED (#",
        manager.propagatedCount, "): requestId=", event.requestId
      if not manager.propagatedFuture.finished():
        manager.propagatedFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  return manager

proc teardown(manager: SendEventListenerManager) {.async.} =
  await MessageSentEvent.dropListener(manager.brokerCtx, manager.sentListener)
  await MessageErrorEvent.dropListener(manager.brokerCtx, manager.errorListener)
  await MessagePropagatedEvent.dropListener(
    manager.brokerCtx, manager.propagatedListener
  )

proc waitForEvents(
    manager: SendEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await allFutures(
    manager.sentFuture, manager.propagatedFuture, manager.errorFuture
  )
    .withTimeout(timeout)

proc outcomes(manager: SendEventListenerManager): set[SendEventOutcome] =
  if manager.sentFuture.completed():
    result.incl(SendEventOutcome.Sent)
  if manager.propagatedFuture.completed():
    result.incl(SendEventOutcome.Propagated)
  if manager.errorFuture.failed():
    result.incl(SendEventOutcome.Error)

proc validate(manager: SendEventListenerManager, expected: set[SendEventOutcome]) =
  echo "EVENT COUNTS: sent=",
    manager.sentCount, ", propagated=", manager.propagatedCount, ", error=",
    manager.errorCount
  check manager.outcomes() == expected

proc validate(
    manager: SendEventListenerManager,
    expected: set[SendEventOutcome],
    expectedRequestId: RequestId,
) =
  manager.validate(expected)
  for requestId in manager.sentRequestIds:
    check requestId == expectedRequestId
  for requestId in manager.propagatedRequestIds:
    check requestId == expectedRequestId
  for requestId in manager.errorRequestIds:
    check requestId == expectedRequestId

suite "Waku API - Send":
  var
    relayNode1 {.threadvar.}: Kernel
    relayNode1PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode1PeerId {.threadvar.}: PeerId

    relayNode2 {.threadvar.}: Kernel
    relayNode2PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode2PeerId {.threadvar.}: PeerId

    lightpushNode {.threadvar.}: Kernel
    lightpushNodePeerInfo {.threadvar.}: RemotePeerInfo
    lightpushNodePeerId {.threadvar.}: PeerId

    storeNode {.threadvar.}: Kernel
    storeNodePeerInfo {.threadvar.}: RemotePeerInfo
    storeNodePeerId {.threadvar.}: PeerId

  asyncSetup:
    lockNewGlobalBrokerContext:
      relayNode1 = newTestWakuNode(generateSecp256k1Key())
      relayNode1.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode1.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode1.mountLibp2pPing()
      (await relayNode1.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error

    lockNewGlobalBrokerContext:
      relayNode2 = newTestWakuNode(generateSecp256k1Key())
      relayNode2.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode2.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode2.mountLibp2pPing()
      (await relayNode2.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error

    lockNewGlobalBrokerContext:
      lightpushNode = newTestWakuNode(generateSecp256k1Key())
      lightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await lightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await lightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await lightpushNode.mountLibp2pPing()
      (await lightpushNode.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error

    lockNewGlobalBrokerContext:
      storeNode = newTestWakuNode(generateSecp256k1Key())
      storeNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await storeNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      # Mount archive so store can persist messages
      let archiveDriver = newSqliteArchiveDriver()
      storeNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await storeNode.mountStore()
      await storeNode.mountLibp2pPing()
      (await storeNode.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error

    relayNode1PeerInfo = relayNode1.peerInfo.toRemotePeerInfo()
    relayNode1PeerId = relayNode1.peerInfo.peerId

    relayNode2PeerInfo = relayNode2.peerInfo.toRemotePeerInfo()
    relayNode2PeerId = relayNode2.peerInfo.peerId

    lightpushNodePeerInfo = lightpushNode.peerInfo.toRemotePeerInfo()
    lightpushNodePeerId = lightpushNode.peerInfo.peerId

    storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()
    storeNodePeerId = storeNode.peerInfo.peerId

    # Subscribe all relay nodes to the default shard topic
    const testPubsubTopic = PubsubTopic("/waku/2/rs/3/0")
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    relayNode1.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode1: " & error
    relayNode2.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode2: " & error

    lightpushNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe lightpushNode: " & error
    storeNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe storeNode: " & error

    # Subscribe all relay nodes to the default shard topic
    await relayNode1.connectToNodes(@[relayNode2PeerInfo, storeNodePeerInfo])
    await lightpushNode.connectToNodes(@[relayNode2PeerInfo])

  asyncTeardown:
    await allFutures(
      relayNode1.stop(), relayNode2.stop(), lightpushNode.stop(), storeNode.stop()
    )

  asyncTest "Check API availability (unhealthy node)":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # node is not connected !

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.messagingClient.send(envelope)

    # TODO: The API is not enforcing a health check before the send,
    #       so currently this test cannot successfully fail to send.
    check sendResult.isOk()

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "A send retried while the node has no relay peer is stored once and counted once as written":
    let root = createTempDir("send-api-archive-", "")
    defer:
      removeDir(root)

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      var conf = defaultTestNodeConf()
      conf.kernel.store = Opt.some(true)
      conf.kernel.storeMessageDbUrl = "sqlite://" & (root / "store.sqlite3")
      node = (await LogosDelivery.new(conf)).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
    defer:
      (await node.stop()).expect("Failed to stop node")

    let
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      insertsBefore = insertCount(relayIngress)
      failuresBefore = errorCount(insertFailure)
      duplicatesBefore = duplicateCount(relayIngress)

    let sendResult = await node.messagingClient.send(
      MessageEnvelope.init(contentTopic, "test payload")
    )
    check sendResult.isOk()

    # The send is retried while the node has no relay peer, and each retry
    # reaches the archive as a message it already holds.
    checkUntilTimeout:
      duplicateCount(relayIngress) >= duplicatesBefore + 2

    let stored = (
      await node.kernel.protocols.archive.findMessages(
        ArchiveQuery(contentTopics: @[contentTopic])
      )
    ).valueOr:
      ArchiveResponse()
    check:
      stored.hashes.len == 1
      insertCount(relayIngress) == insertsBefore + 1
      errorCount(insertFailure) == failuresBefore

  asyncTest "Send fully validated":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    check await eventManager.sentFuture.withTimeout(eventTimeout)

    eventManager.validate(
      {SendEventOutcome.Sent, SendEventOutcome.Propagated}, requestId
    )

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Burst of sends is fully validated":
    ## Confirm all requests across multiple Store pages and validation batches.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    const burst = 120
    let allSent = newAsyncEvent()
    var sentCount = 0
    let onSent = proc(event: MessageSentEvent) {.async: (raises: []).} =
      inc sentCount
      if sentCount == burst:
        allSent.fire()
    let counter =
      MessageSentEvent.listen(node.kernel.brokerCtx, onSent).expect("listen")
    defer:
      await MessageSentEvent.dropListener(node.kernel.brokerCtx, counter)

    var requestIds: HashSet[RequestId]
    for i in 0 ..< burst:
      let envelope = MessageEnvelope.init(
        ContentTopic("/waku/2/default-content/proto"), "burst payload " & $i
      )
      let requestId = (await node.messagingClient.send(envelope)).valueOr:
        raiseAssert "send failed: " & error
      requestIds.incl(requestId)
    check requestIds.len == burst

    # 120 messages require at least two validation batches.
    check:
      await allSent.wait().withTimeout(30.seconds)
      eventManager.sentRequestIds.toHashSet() == requestIds
      eventManager.sentCount == burst
      eventManager.errorCount == 0

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(@[relayNode1PeerInfo])

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send only propagates fallback to lightpush":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(@[lightpushNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Edge sender delivers via lightpush (no relay)":
    ## Reproduces issue #3847: an Edge node (no relay mounted) that is only
    ## connected to a lightpush-capable peer must deliver through lightpush.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      # Edge node has no relay; its only path to the network is the
      # lightpush peer it is connected to.
      await node.kernel.connectToNodes(@[lightpushNodePeerInfo])

    check node.kernel.protocols.relay.isNil()

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "S16 - isolated sender recovers when lightpush peer appears later":
    ## Edge sender starts with no peer; a lightpush peer appears mid-send and a
    ## later retry must deliver the queued message.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # No connectToNodes: the sender has no reachable peer at T0.

    check node.kernel.protocols.relay.isNil()

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    # send() with no peer must still succeed; the message is queued and retried.
    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    # Nothing should propagate while isolated (retry interval is 1s).
    await sleepAsync(5.seconds)
    check eventManager.propagatedCount == 0

    # The lightpush peer appears; a later retry must now deliver.
    await node.kernel.connectToNodes(@[lightpushNodePeerInfo])

    const eventTimeout = 10.seconds
    discard await eventManager.waitForEvents(eventTimeout)

    eventManager.validate({SendEventOutcome.Propagated}, requestId)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fully validates fallback to lightpush":
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(@[lightpushNodePeerInfo, storeNodePeerInfo])

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    check await eventManager.sentFuture.withTimeout(eventTimeout)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Sent}, requestId
    )
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Send fails with event":
    var fakeLightpushNode: Kernel
    lockNewGlobalBrokerContext:
      fakeLightpushNode = newTestWakuNode(generateSecp256k1Key())
      fakeLightpushNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await fakeLightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await fakeLightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await fakeLightpushNode.mountLibp2pPing()
      (await fakeLightpushNode.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error
    let fakeLightpushNodePeerInfo = fakeLightpushNode.peerInfo.toRemotePeerInfo()
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    fakeLightpushNode.subscribe(
      (kind: PubsubSub, topic: PubsubTopic("/waku/2/rs/3/0")), dummyHandler
    ).isOkOr:
      raiseAssert "Failed to subscribe fakeLightpushNode: " & error

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(@[fakeLightpushNodePeerInfo])

    node.messagingClient.sendService.maxDeliveryTime = 5.seconds

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    echo "Sent message with requestId=", requestId
    # Wait for events with timeout
    const eventTimeout = 30.seconds
    check await eventManager.errorFuture.withTimeout(eventTimeout)

    eventManager.validate({SendEventOutcome.Error}, requestId)
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Edge send whose meta exceeds the limit fails at once with the service's reason":
    ## The lightpush service rejects the request as BAD_REQUEST, which is not
    ## retried, so the send fails after the first attempt.
    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (
        await LogosDelivery.new(
          defaultTestNodeConf(messaging_conf.LogosDeliveryMode.Edge)
        )
      ).valueOr:
        raiseAssert error
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.kernel.connectToNodes(@[lightpushNodePeerInfo])
    defer:
      (await node.stop()).expect("Failed to stop node")

    node.messagingClient.sendService.maxDeliveryTime = 5.seconds

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let rejectedBefore =
      try:
        logos_delivery_lightpush_v3_errors.value([$LightPushErrorCode.BAD_REQUEST])
      except KeyError:
        0.0

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"),
      "test payload",
      meta = newSeq[byte](MaxMetaAttrLength + 1),
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    check await eventManager.errorFuture.withTimeout(30.seconds)

    let rejected =
      try:
        logos_delivery_lightpush_v3_errors.value([$LightPushErrorCode.BAD_REQUEST]) -
          rejectedBefore
      except KeyError:
        0.0

    eventManager.validate({SendEventOutcome.Error}, requestId)
    check:
      eventManager.errorDescs ==
        @["decode_rpc_failure: (kind: InvalidLengthField, field: \"meta\")"]
      rejected == 1.0

  asyncTest "A send retried while the node has no relay peer is handed to the relay handlers on every attempt and received once":
    # TODO: logos-delivery#4453
    # Given a core node with REST that is connected to no peer
    var node: LogosDelivery
    var rest: RestService
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf(rest = true))).valueOr:
        raiseAssert error
      node.shortenIntervals()
      rest = (await node.startWithRest()).valueOr:
        raiseAssert "Failed to start Waku node: " & error

    node.messagingClient.sendService.maxDeliveryTime = 5.seconds

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    var receivedHashes: seq[string]
    let receivedListener = MessageReceivedEvent.listen(
      node.kernel.brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        receivedHashes.add(event.messageHash),
    ).valueOr:
      raiseAssert error
    defer:
      await MessageReceivedEvent.dropListener(node.kernel.brokerCtx, receivedListener)

    let
      client = newRestHttpClient(rest.server.localAddress())
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "test payload"
    let subscribeResponse = await client.relayPostAutoSubscriptionsV1(@[contentTopic])
    let handledBefore = nodeMessagesCount(["relay"])

    # When it sends a message
    let requestId = (
      await node.messagingClient.send(MessageEnvelope.init(contentTopic, payload))
    ).valueOr:
      raiseAssert error

    # Then the relay cache returns the message again after a later attempt
    let first = await client.waitForRelayAutoMessages(contentTopic, 1)
    let handledAtFirstRead = nodeMessagesCount(["relay"])
    checkUntilTimeout:
      nodeMessagesCount(["relay"]) > handledAtFirstRead
    let again = await client.waitForRelayAutoMessages(contentTopic, 1)

    # Then the send ends with an error event, and the message was received once
    check await eventManager.errorFuture.withTimeout(30.seconds)
    eventManager.validate({SendEventOutcome.Error}, requestId)
    check:
      subscribeResponse.status == 200
      first.mapIt(it.payload) == @[base64.encode(payload)]
      again.mapIt(it.payload) == @[base64.encode(payload)]
      nodeMessagesCount(["relay"]) >= handledBefore + 2
      receivedHashes.len == 1

    await rest.stop(node)

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Store validation times out with an error event":
    ## The message propagates, but the only reachable store node is outside the
    ## relay mesh and never holds it. Once the validation window elapses the send
    ## reports Propagated, then Error, and never Sent.
    var isolatedStoreNode: Kernel
    lockNewGlobalBrokerContext:
      isolatedStoreNode = newTestWakuNode(generateSecp256k1Key())
      isolatedStoreNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await isolatedStoreNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      let archiveDriver = newSqliteArchiveDriver()
      isolatedStoreNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await isolatedStoreNode.mountStore()
      await isolatedStoreNode.mountLibp2pPing()
      (await isolatedStoreNode.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error
    # Deliberately NOT subscribed to the topic and NOT wired into the relay mesh, so
    # it can answer store queries but never holds the published message.
    let isolatedStoreNodePeerInfo = isolatedStoreNode.peerInfo.toRemotePeerInfo()

    var node: LogosDelivery
    lockNewGlobalBrokerContext:
      node = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      node.shortenIntervals()
      (await node.start()).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      # Propagate via relayNode1; store queries can only reach the isolated store node.
      await node.kernel.connectToNodes(@[relayNode1PeerInfo, isolatedStoreNodePeerInfo])

    # Longer than `archiveTime`, so the store node is queried first.
    node.messagingClient.sendService.maxValidationAge = 2.seconds

    let eventManager = newSendEventListenerManager(node.kernel.brokerCtx)
    defer:
      await eventManager.teardown()

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let requestId = (await node.messagingClient.send(envelope)).valueOr:
      raiseAssert error

    check await eventManager.errorFuture.withTimeout(30.seconds)

    eventManager.validate(
      {SendEventOutcome.Propagated, SendEventOutcome.Error}, requestId
    )

    (await isolatedStoreNode.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error
    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

## Checks that the caller gets the request id before any event of the send. The
## node has a budget of 0, so each send emits an event with no network call. A
## durable message gets `MessageQueuedEvent` and an ephemeral one gets
## `MessageErrorEvent`.

const OrderTopic = ContentTopic("/test/1/send-order/proto")

type OrderLog = ref object
  ids: seq[RequestId] ## The ids that the callers got, in order.
  events: seq[RequestId]
  early: seq[RequestId] ## The events for an id that no caller had yet.

proc record(log: OrderLog, id: RequestId) =
  log.events.add(id)
  if id notin log.ids:
    log.early.add(id)

proc keepId(log: OrderLog, res: Result[RequestId, string]) =
  ## Records the id when the caller gets it. A refused send records an empty id.
  log.ids.add(res.get(RequestId("")))

proc noBudgetNode(capacity: uint): Future[LogosDelivery] {.async.} =
  ## A started node whose rate limit admits no message.
  var node: LogosDelivery
  lockNewGlobalBrokerContext:
    node = (
      await LogosDelivery.new(
        KernelConf(defaultTestNodeConf().kernel),
        MessagingClientConf(
          rateLimitEnabled: Opt.some(true),
          rateLimitMessagesPerEpoch: Opt.some(0'u64),
          sendQueueCapacity: Opt.some(capacity),
        ),
        ReliableChannelManagerConf(),
      )
    ).expect("LogosDelivery.new")
    (await node.start()).expect("start")
  return node

suite "Messaging API - the request id comes before the events":
  asyncTest "send and the MessagingSend provider return a finished future":
    ## Both futures are finished when the call returns, and the task is in the
    ## send queue.
    let node = await noBudgetNode(capacity = 4)
    defer:
      (await node.stop()).expect("stop")
    let client = node.messagingClient

    let direct = client.send(MessageEnvelope.init(OrderTopic, "direct"))
    let viaBroker = MessagingSend.request(
      node.kernel.brokerCtx, MessageEnvelope.init(OrderTopic, "broker")
    )
    check:
      direct.finished()
      viaBroker.finished()
    if direct.finished() and viaBroker.finished():
      check:
        direct.read().isOk()
        viaBroker.read().isOk()

    # The node has room for 4 tasks, the 2 sends above and 2 more.
    for i in 0 ..< 2:
      check (await client.send(MessageEnvelope.init(OrderTopic, "fill-" & $i))).isOk()
    check:
      client.sendService.isFull()
      (await client.send(MessageEnvelope.init(OrderTopic, "over"))).errorOr("accepted") ==
        "Send queue full, retry later"

    # A refused send leaves no subscription behind.
    const RefusedTopic = ContentTopic("/test/1/send-order-refused/proto")
    check:
      (await client.send(MessageEnvelope.init(RefusedTopic, "refused"))).errorOr(
        "accepted"
      ) == "Send queue full, retry later"
      not node.kernel.isSubscribed(RefusedTopic).valueOr(true)

  asyncTest "no event comes before its request id, durable and ephemeral":
    let node = await noBudgetNode(capacity = 100)
    defer:
      (await node.stop()).expect("stop")
    let client = node.messagingClient
    let brokerCtx = node.kernel.brokerCtx

    let log = OrderLog()
    let queuedListener = MessageQueuedEvent
      .listen(
        brokerCtx,
        proc(event: MessageQueuedEvent) {.async: (raises: []).} =
          log.record(event.requestId),
      )
      .expect("listen queued")
    let errorListener = MessageErrorEvent
      .listen(
        brokerCtx,
        proc(event: MessageErrorEvent) {.async: (raises: []).} =
          log.record(event.requestId),
      )
      .expect("listen error")
    defer:
      await MessageQueuedEvent.dropListener(brokerCtx, queuedListener)
      await MessageErrorEvent.dropListener(brokerCtx, errorListener)

    # Each batch sends two messages through the client and two through the
    # broker. A durable task parks and an ephemeral task fails.
    for batch in 0 ..< 3:
      proc envelope(kind: string, ephemeral = false): MessageEnvelope =
        MessageEnvelope.init(OrderTopic, kind & "-" & $batch, ephemeral = ephemeral)

      log.keepId(await client.send(envelope("durable")))
      log.keepId(await client.send(envelope("ephemeral", ephemeral = true)))
      log.keepId(await MessagingSend.request(brokerCtx, envelope("broker-durable")))
      log.keepId(
        await MessagingSend.request(
          brokerCtx, envelope("broker-ephemeral", ephemeral = true)
        )
      )
      checkUntilTimeoutCustom(FUTURE_TIMEOUT_MEDIUM, chronos.milliseconds(5)):
        log.events.len == log.ids.len

    check:
      log.ids.len == 12
      RequestId("") notin log.ids # each send got an id
      log.early.len == 0
