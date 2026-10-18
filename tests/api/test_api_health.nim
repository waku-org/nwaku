{.used.}

import results, std/[sequtils]
import chronos, testutils/unittests, libp2p/[switch, peerinfo]
import brokers/broker_context
import ../testlib/[wakucore, wakunode, wakunodeconf, testasync]

import
  logos_delivery/kernel/[
    api/kernel_lifecycle,
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/message,
    base/peers,
    protocols/relay/protocol,
    base/health/topic_health,
    base/health/health_status,
    base/health/protocol_health,
    base/health/health_report,
    base/health/health_requests,
    base/topics/relay_shard_request,
    api/events/health_events,
  ],
  logos_delivery
import tools/confutils/cli_args

const TestTimeout = chronos.seconds(10)
const DefaultShard = PubsubTopic("/waku/2/rs/3/0")
const TestContentTopic = ContentTopic("/waku/2/default-content/proto")

proc dummyHandler(
    topic: PubsubTopic, msg: WakuMessage
): Future[void] {.async, gcsafe.} =
  discard

proc waitForConnectionStatus(
    brokerCtx: BrokerContext, expected: ConnectionStatus
) {.async.} =
  var future = newFuture[void]("waitForConnectionStatus")

  let handler: EventConnectionStatusChangeListenerProc = proc(
      e: EventConnectionStatusChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished:
      if e.connectionStatus == expected:
        future.complete()

  let handle = EventConnectionStatusChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if not await future.withTimeout(TestTimeout):
      raiseAssert "Timeout waiting for status: " & $expected
  finally:
    await EventConnectionStatusChange.dropListener(brokerCtx, handle)

proc waitForShardHealthy(
    brokerCtx: BrokerContext
): Future[EventShardTopicHealthChange] {.async.} =
  var future = newFuture[EventShardTopicHealthChange]("waitForShardHealthy")

  let handler: EventShardTopicHealthChangeListenerProc = proc(
      e: EventShardTopicHealthChange
  ) {.async: (raises: []), gcsafe.} =
    if not future.finished:
      if e.health == TopicHealth.MINIMALLY_HEALTHY or
          e.health == TopicHealth.SUFFICIENTLY_HEALTHY:
        future.complete(e)

  let handle = EventShardTopicHealthChange.listen(brokerCtx, handler).valueOr:
    raiseAssert error

  try:
    if await future.withTimeout(TestTimeout):
      return future.read()
    else:
      raiseAssert "Timeout waiting for shard health event"
  finally:
    await EventShardTopicHealthChange.dropListener(brokerCtx, handle)

suite "LM API health checking":
  var
    serviceNode {.threadvar.}: Kernel
    client {.threadvar.}: LogosDelivery
    servicePeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    lockNewGlobalBrokerContext:
      serviceNode = newTestWakuNode(generateSecp256k1Key())
      (await serviceNode.mountRelay()).isOkOr:
        raiseAssert error
      serviceNode.mountMetadata(TestClusterId, @[0'u16]).isOkOr:
        raiseAssert error
      await serviceNode.mountLibp2pPing()
      (await serviceNode.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error

    servicePeerInfo = serviceNode.peerInfo.toRemotePeerInfo()
    serviceNode.protocols.relay.subscribe(DefaultShard, dummyHandler)

    lockNewGlobalBrokerContext:
      client = (await LogosDelivery.new(defaultTestNodeConf())).valueOr:
        raiseAssert error
      (await client.start()).isOkOr:
        raiseAssert error

  asyncTeardown:
    discard await client.stop()
    (await serviceNode.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "RequestShardTopicsHealth, check PubsubTopic health":
    client.kernel.protocols.relay.subscribe(DefaultShard, dummyHandler)
    await client.kernel.connectToNodes(@[servicePeerInfo])

    var isHealthy = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestShardTopicsHealth.request(
        client.kernel.brokerCtx, @[DefaultShard]
      ).valueOr:
        raiseAssert "RequestShardTopicsHealth failed"

      if req.topicHealth.len > 0:
        let h = req.topicHealth[0].health
        if h == TopicHealth.MINIMALLY_HEALTHY or h == TopicHealth.SUFFICIENTLY_HEALTHY:
          isHealthy = true
          break
      await sleepAsync(chronos.milliseconds(100))

    check isHealthy == true

  asyncTest "RequestShardTopicsHealth, check disconnected PubsubTopic":
    const GhostShard = PubsubTopic("/waku/2/rs/1/666")
    client.kernel.protocols.relay.subscribe(GhostShard, dummyHandler)

    let req = RequestShardTopicsHealth.request(client.kernel.brokerCtx, @[GhostShard]).valueOr:
      raiseAssert "Request failed"

    check req.topicHealth.len > 0
    check req.topicHealth[0].health == TopicHealth.UNHEALTHY

  asyncTest "RequestProtocolHealth, check relay status":
    await client.kernel.connectToNodes(@[servicePeerInfo])

    var isReady = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let relayReq = await RequestProtocolHealth.request(
        client.kernel.brokerCtx, ProtocolName.RelayProtocol
      )
      if relayReq.isOk() and relayReq.get().healthStatus.health == HealthStatus.READY:
        isReady = true
        break
      await sleepAsync(chronos.milliseconds(100))

    check isReady == true

    let storeReq = await RequestProtocolHealth.request(
      client.kernel.brokerCtx, ProtocolName.StoreProtocol
    )
    if storeReq.isOk():
      check storeReq.get().healthStatus.health != HealthStatus.READY

  asyncTest "RequestProtocolHealth, check unmounted protocol":
    let req = await RequestProtocolHealth.request(
      client.kernel.brokerCtx, ProtocolName.StoreProtocol
    )
    check req.isOk()

    let status = req.get().healthStatus
    check status.health == HealthStatus.NOT_MOUNTED
    check status.desc.isNone()

  asyncTest "RequestConnectionStatus, check connectivity state":
    let initialReq = RequestConnectionStatus.request(client.kernel.brokerCtx).valueOr:
      raiseAssert "RequestConnectionStatus failed"
    check initialReq.connectionStatus == ConnectionStatus.Disconnected

    await client.kernel.connectToNodes(@[servicePeerInfo])

    var isConnected = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestConnectionStatus.request(client.kernel.brokerCtx).valueOr:
        raiseAssert "RequestConnectionStatus failed"

      if req.connectionStatus == ConnectionStatus.PartiallyConnected or
          req.connectionStatus == ConnectionStatus.Connected:
        isConnected = true
        break
      await sleepAsync(chronos.milliseconds(100))

    check isConnected == true

  asyncTest "getConnectionStatus, reads the last reported status":
    check (await client.getConnectionStatus()).get() == ConnectionStatus.Disconnected

    let connectFuture = waitForConnectionStatus(
      client.kernel.brokerCtx, ConnectionStatus.PartiallyConnected
    )
    await client.kernel.connectToNodes(@[servicePeerInfo])
    await connectFuture

    check (await client.getConnectionStatus()).get() ==
      ConnectionStatus.PartiallyConnected

  asyncTest "EventConnectionStatusChange, detect connect and disconnect":
    let connectFuture = waitForConnectionStatus(
      client.kernel.brokerCtx, ConnectionStatus.PartiallyConnected
    )

    await client.kernel.connectToNodes(@[servicePeerInfo])
    await connectFuture

    let disconnectFuture =
      waitForConnectionStatus(client.kernel.brokerCtx, ConnectionStatus.Disconnected)
    await client.kernel.disconnectNode(servicePeerInfo)
    await disconnectFuture

  asyncTest "EventShardTopicHealthChange, detect health improvement":
    client.kernel.protocols.relay.subscribe(DefaultShard, dummyHandler)

    let healthEventFuture = waitForShardHealthy(client.kernel.brokerCtx)

    await client.kernel.connectToNodes(@[servicePeerInfo])

    let event = await healthEventFuture
    check event.topic == DefaultShard

  asyncTest "RequestHealthReport, check aggregate report":
    let req = await RequestHealthReport.request(client.kernel.brokerCtx)

    check req.isOk()

    let report = req.get().healthReport
    check report.nodeHealth == HealthStatus.READY
    check report.protocolsHealth.len > 0
    check report.protocolsHealth.anyIt(it.protocol == $ProtocolName.RelayProtocol)

  asyncTest "RequestContentTopicsHealth, smoke test":
    let fictionalTopic = ContentTopic("/waku/2/this-does-not-exist/proto")

    let req =
      RequestContentTopicsHealth.request(client.kernel.brokerCtx, @[fictionalTopic])

    check req.isOk()

    let res = req.get()
    check res.contentTopicHealth.len == 1
    check res.contentTopicHealth[0].topic == fictionalTopic
    check res.contentTopicHealth[0].health == TopicHealth.NOT_SUBSCRIBED

  asyncTest "RequestContentTopicsHealth, core mode trivial 1-shard autosharding":
    let cTopic = ContentTopic("/waku/2/my-content-topic/proto")

    let shardReq =
      RequestRelayShard.request(client.kernel.brokerCtx, Opt.none(PubsubTopic), cTopic)

    check shardReq.isOk()
    let targetShard = $shardReq.get().relayShard

    client.kernel.protocols.relay.subscribe(targetShard, dummyHandler)
    serviceNode.protocols.relay.subscribe(targetShard, dummyHandler)

    await client.kernel.connectToNodes(@[servicePeerInfo])

    var isHealthy = false
    let start = Moment.now()
    while Moment.now() - start < TestTimeout:
      let req = RequestContentTopicsHealth.request(client.kernel.brokerCtx, @[cTopic]).valueOr:
        raiseAssert "Request failed"

      if req.contentTopicHealth.len > 0:
        let h = req.contentTopicHealth[0].health
        if h == TopicHealth.MINIMALLY_HEALTHY or h == TopicHealth.SUFFICIENTLY_HEALTHY:
          isHealthy = true
          break

      await sleepAsync(chronos.milliseconds(100))

    check isHealthy == true

  asyncTest "RequestProtocolHealth, edge mode smoke test":
    var edgeWaku: LogosDelivery

    lockNewGlobalBrokerContext:
      var edgeConf = defaultTestWakuNodeConf(mode = Edge)
      edgeConf.maxMessageSize = "150 KiB"

      edgeWaku = (await LogosDelivery.new(testNodeConf(edgeConf, mode = Edge))).valueOr:
        raiseAssert "Failed to create edge node: " & error

      (await edgeWaku.start()).isOkOr:
        raiseAssert "Failed to start edge waku: " & error

      let relayReq = await RequestProtocolHealth.request(
        edgeWaku.kernel.brokerCtx, ProtocolName.RelayProtocol
      )
      check relayReq.isOk()
      check relayReq.get().healthStatus.health == HealthStatus.NOT_MOUNTED

      check not edgeWaku.kernel.protocols.filterClient.isNil()

      discard await edgeWaku.stop()
