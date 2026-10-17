{.used.}

import
  results,
  std/[net, sequtils, strutils, tables],
  testutils/unittests,
  chronos,
  chronos/transports/[stream, datagram, common],
  metrics,
  metrics/chronos_httpserver,
  libp2p/[crypto/crypto, multiaddress, protocols/connectivity/relay/relay],
  eth/p2p/discoveryv5/enr

import tools/confutils/cli_args

import
  tests/testlib/[wakunode, wakucore],
  logos_delivery/kernel/[
    topics/content_topic,
    topics/pubsub_topic,
    node/peer_manager/peers,
    protocols/codecs,
    kernel_lifecycle,
    protocols/store/common,
    protocols/store/client,
    protocols/store/rpc_codec,
    net/net_config,
    common/enr/typed_record,
    enr/multiaddr,
    enr/sharding,
    discovery/discv5,
    node/peer_manager/peer_manager,
    node/metrics_server,
    protocols/metadata/protocol,
    protocols/filter/common,
    protocols/filter/protocol,
  ],
  logos_delivery/kernel/node/subscription_manager,
  logos_delivery/kernel/factory/[
    internal_config,
    networks_config,
    conf_builder/conf_builder,
    conf_builder/filter_service_conf_builder,
    conf_builder/store_service_conf_builder,
    conf_builder/discv5_conf_builder,
    conf_builder/metrics_server_conf_builder,
  ]

proc servicePeerGauge(codec: string): float64 =
  try:
    return logos_delivery_service_peers.value([codec])
  except KeyError:
    return 0.0

suite "Node Factory":
  asynctest "Set up a node based on default configurations":
    let conf = defaultTestWakuConf()

    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not kernel.isNil()
      kernel.protocols.archive.isNil()
      kernel.protocols.store.isNil()
      kernel.protocols.filter.isNil()
      not kernel.protocols.storeClient.isNil()
      not kernel.discovery.rendezvous.isNil()

  asynctest "The store client reads a full page of the configured message size":
    var conf = defaultTestWakuConf()
    conf.maxMessageSizeBytes = 1024 * 1024

    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check kernel.protocols.storeClient.maxResponseSize ==
      maxQueryResponseSize(1024 * 1024)

  asynctest "Set up a node with Store enabled":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.storeServiceConf.withEnabled(true)
    confBuilder.storeServiceConf.withDbUrl("sqlite://store.sqlite3")
    let conf = confBuilder.build().value

    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    check:
      not kernel.isNil()
      not kernel.protocols.store.isNil()
      not kernel.protocols.archive.isNil()

  asynctest "The command line default rate limits reach the mounted protocols":
    # Given the configuration of a binary started without --rate-limit
    let conf = defaultKernelConf().get().toWakuConf().valueOr:
        raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then each protocol is mounted with the limit the command line assigns
    let
      filterLimit = kernel.protocols.filter.peerRequestRateLimiter.setting
      lightPushLimit = kernel.protocols.lightPush.requestRateLimiter.setting
      peerExchangeLimit = kernel.discovery.peerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 5, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "A command line lightpush rate limit keeps the filter and peer exchange defaults":
    # Given the configuration of a binary started with --rate-limit=lightpush:100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["lightpush:100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then only lightpush changes, filter and peer exchange keep their defaults
    let
      filterLimit = kernel.protocols.filter.peerRequestRateLimiter.setting
      lightPushLimit = kernel.protocols.lightPush.requestRateLimiter.setting
      peerExchangeLimit = kernel.discovery.peerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 100, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "A command line rate limit without a protocol applies to every protocol":
    # Given the configuration of a binary started with --rate-limit=100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then every protocol takes the global limit
    let
      filterLimit = kernel.protocols.filter.peerRequestRateLimiter.setting
      lightPushLimit = kernel.protocols.lightPush.requestRateLimiter.setting
      peerExchangeLimit = kernel.discovery.peerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 100, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 100, period: 1.seconds))

  asynctest "A command line store rate limit keeps the service defaults":
    # Given the configuration of a binary started with --rate-limit=store:10/1s
    var cliConf = defaultKernelConf().get()
    cliConf.rateLimits = @["store:10/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then filter, lightpush and peer exchange keep their defaults
    let
      filterLimit = kernel.protocols.filter.peerRequestRateLimiter.setting
      lightPushLimit = kernel.protocols.lightPush.requestRateLimiter.setting
      peerExchangeLimit = kernel.discovery.peerExchange.requestRateLimiter.setting

    check:
      filterLimit == Opt.some((volume: 100, period: 1.seconds))
      lightPushLimit == Opt.some((volume: 5, period: 1.seconds))
      peerExchangeLimit == Opt.some((volume: 5, period: 1.seconds))

  asynctest "The command line default rate limits let the filter service accept 31 subscribes in a row":
    # Given a node set up from the configuration of a binary started without --rate-limit
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # And a filter client
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(kernel.start(), client.start())
    defer:
      await allFutures(kernel.stop(), client.stop())
    await client.mountFilterClient()
    let serverRemotePeerInfo = kernel.switch.peerInfo.toRemotePeerInfo()

    # When the client sends 31 subscribes in a row
    var subscribeResults: seq[FilterSubscribeResult]
    for _ in 0 ..< 31:
      subscribeResults.add(
        await client.filterSubscribe(
          Opt.some(DefaultPubsubTopic), DefaultContentTopic, serverRemotePeerInfo
        )
      )

    # Then the filter service accepts all of them
    check subscribeResults.allIt(it.isOk())

  asynctest "A command line lightpush rate limit keeps the filter service accepting 31 subscribes in a row":
    # Given a node set up from the configuration of a binary started with --rate-limit=lightpush:100/1s
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    cliConf.rateLimits = @["lightpush:100/1s"]
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # And a filter client
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(kernel.start(), client.start())
    defer:
      await allFutures(kernel.stop(), client.stop())
    await client.mountFilterClient()
    let serverRemotePeerInfo = kernel.switch.peerInfo.toRemotePeerInfo()

    # When the client sends 31 subscribes in a row
    var subscribeResults: seq[FilterSubscribeResult]
    for _ in 0 ..< 31:
      subscribeResults.add(
        await client.filterSubscribe(
          Opt.some(DefaultPubsubTopic), DefaultContentTopic, serverRemotePeerInfo
        )
      )

    # Then the filter service accepts all of them
    check subscribeResults.allIt(it.isOk())

  asynctest "The storenode command line option fills the store service slot":
    # Given the configuration of a binary started with --storenode
    let
      storePeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      storeAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.storenode = storeAddress & "/p2p/" & $storePeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the store service slot
    check:
      kernel.peerManager.serviceSlots[WakuStoreCodec].peerId == storePeerId
      servicePeerGauge(WakuStoreCodec) == 1

  asynctest "The storenode command line option fills the store sync service slots":
    # Given the configuration of a binary started with --store, --store-sync and --storenode
    let
      storePeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      storeAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.store = Opt.some(true)
    cliConf.storeMessageDbUrl = "sqlite://store.sqlite3"
    cliConf.storeSync = true
    cliConf.storenode = storeAddress & "/p2p/" & $storePeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the reconciliation and transfer service slots
    check:
      kernel.peerManager.serviceSlots[WakuReconciliationCodec].peerId == storePeerId
      kernel.peerManager.serviceSlots[WakuTransferCodec].peerId == storePeerId

  asynctest "The filternode command line option fills the filter service slot":
    # Given the configuration of a binary started with --filternode
    let
      filterPeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      filterAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.filternode = filterAddress & "/p2p/" & $filterPeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the filter service slot
    check:
      kernel.peerManager.serviceSlots[WakuFilterSubscribeCodec].peerId == filterPeerId
      servicePeerGauge(WakuFilterSubscribeCodec) == 1

  asynctest "The lightpushnode command line option fills the lightpush service slot":
    # Given the configuration of a binary started with --lightpushnode
    let
      lightPushPeerId = PeerId.init(generateSecp256k1Key()).tryGet()
      lightPushAddress = "/ip4/127.0.0.1/tcp/60000"
    var cliConf = defaultKernelConf().get()
    cliConf.lightpushnode = lightPushAddress & "/p2p/" & $lightPushPeerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error

    # Then that peer holds the lightpush service slot
    check:
      kernel.peerManager.serviceSlots[WakuLightPushCodec].peerId == lightPushPeerId
      servicePeerGauge(WakuLightPushCodec) == 1

  asynctest "The peer-exchange-node command line option fills the peer exchange service slot and fetches its peers at start":
    # Given a peer exchange responder that discovered a peer via Discv5
    let
      responder = newTestWakuNode(generateSecp256k1Key())
      discoveredNode = newTestWakuNode(generateSecp256k1Key())
    # The node disconnects a peer that does not report its cluster id through the metadata protocol.
    check:
      responder.mountMetadata(DefaultClusterId, @[]).isOk()
      discoveredNode.mountMetadata(DefaultClusterId, @[]).isOk()
    await allFutures(responder.start(), discoveredNode.start())
    defer:
      await allFutures(responder.stop(), discoveredNode.stop())
    await responder.mountPeerExchange()
    var discoveredPeer = discoveredNode.peerInfo.toRemotePeerInfo()
    discoveredPeer.enr = Opt.some(discoveredNode.enr)
    responder.peerManager.addPeer(discoveredPeer, PeerOrigin.Discv5)

    # And the configuration of a binary started with --peer-exchange-node naming the responder
    var cliConf = defaultKernelConf().get()
    cliConf.tcpPort = Port(0)
    cliConf.peerExchangeNode =
      "/ip4/127.0.0.1/tcp/" & $responder.boundTcpPort() & "/p2p/" &
      $responder.peerInfo.peerId
    let conf = cliConf.toWakuConf().valueOr:
      raiseAssert error

    # When the node is set up and started
    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error
    let startResult = await startNode(kernel, conf)
    defer:
      (await kernel.stop()).isOkOr:
        raiseAssert "failed to stop kernel: " & error

    # Then the responder holds the peer exchange service slot, and the peer it discovered is in the peer store
    check:
      startResult.isOk()
      kernel.peerManager.serviceSlots[WakuPeerExchangeCodec].peerId ==
        responder.peerInfo.peerId
      kernel.peerManager.switch.peerStore.peers.anyIt(
        it.peerId == discoveredPeer.peerId and it.origin == PeerExchange
      )

  asynctest "A content topic's autoshard is advertised in the ENR and metadata":
    # Given a node subscribed to shard 0 and a content topic that maps to shard 3
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.withNumShardsInCluster(8)
    confBuilder.withContentTopics(@["/toychat/2/huilong/proto"])
    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error
    let client = newTestWakuNode(generateSecp256k1Key(), clusterId = conf.clusterId)
    client.mountMetadata(conf.clusterId, @[]).isOkOr:
      raiseAssert error
    await allFutures(kernel.start(), client.start())
    defer:
      await allFutures(kernel.stop(), client.stop())

    # When a peer asks for its metadata
    let conn = (
      await client.peerManager.dialPeer(
        kernel.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec
      )
    ).valueOr:
      raiseAssert "could not dial metadata"
    let metadata = (await client.protocols.metadata.request(conn)).valueOr:
      raiseAssert error

    # Then both the ENR and the metadata advertise the content topic's shard
    let enrShards = kernel.enr.toTyped().get().relaySharding().get()
    check:
      enrShards.shardIds == @[0'u16, 3'u16]
      metadata.shards == @[0'u32, 3'u32]

  asynctest "Extra listen shards reach the node and its content-topic subscriptions":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.withAutoshardingShards(@[32'u16])
    confBuilder.withSubscribeShards(@[32'u16])
    confBuilder.withExtraListenShards(@[64'u16])
    let conf = confBuilder.build().valueOr:
      raiseAssert error

    let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
      raiseAssert error
    let listenShard = $RelayShard(clusterId: conf.clusterId, shardId: 64)

    check kernel.subscriptionManager.extraListenShards == @[PubsubTopic(listenShard)]

    kernel.subscriptionManager.subscribe(ContentTopic("/toychat/2/huilong/proto")).isOkOr:
      raiseAssert error
    check:
      PubsubTopic($RelayShard(clusterId: conf.clusterId, shardId: 32)) in
        kernel.subscriptionManager.shards
      PubsubTopic(listenShard) in kernel.subscriptionManager.shards

  test "Extra listen shards need auto-sharding":
    var confBuilder = defaultTestWakuConfBuilder()
    confBuilder.withShardingConf(StaticSharding)
    confBuilder.withExtraListenShards(@[64'u16])

    check confBuilder.build().isErr()

  test "ENR configuration trims multiaddrs until record fits":
    var conf = defaultTestWakuConf()
    let bindIp = conf.endpointConf.p2pListenAddress
    let bindPort = Port(30303)

    let oversizedMultiaddrs = (0 .. 11).mapIt(
      MultiAddress
        .init(
          "/dns4/very-long-logical-hostname-" & $it &
            ".example.logos.dev.status.im/tcp/30303/wss"
        )
        .get()
    )

    let netConfig = NetConfig.init(
      clusterId = conf.clusterId,
      bindIp = bindIp,
      bindPort = bindPort,
      extMultiAddrs = oversizedMultiaddrs,
      extMultiAddrsOnly = true,
      wakuFlags = Opt.some(conf.wakuFlags),
    ).valueOr:
      raiseAssert error

    let record = enrConfiguration(conf, netConfig).valueOr:
      raiseAssert error

    let typedRecord = record.toTyped()
    require typedRecord.isOk()

    let multiaddrsOpt = typedRecord.value.multiaddrs
    require multiaddrsOpt.isSome()

    let retainedMultiaddrs = multiaddrsOpt.get()
    check:
      retainedMultiaddrs.len < oversizedMultiaddrs.len
      retainedMultiaddrs.len > 0
      retainedMultiaddrs == oversizedMultiaddrs[0 ..< retainedMultiaddrs.len]

asynctest "Set up a node with Filter enabled":
  var confBuilder = defaultTestWakuConfBuilder()
  confBuilder.filterServiceConf.withEnabled(true)
  let conf = confBuilder.build().value

  let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
    raiseAssert error

  check:
    not kernel.isNil()
    not kernel.protocols.filter.isNil()
  echo "TEST END"

asynctest "Start a node based on default test configuration":
  let conf = defaultTestWakuConf()

  let kernel = (await setupNode(conf, relay = Relay.new())).valueOr:
    raiseAssert error

  assert not kernel.isNil(), "Node can't be nil"

  let startRes = catch:
    (await startNode(kernel, conf))

  assert not startRes.isErr(), "Exception starting node"
  assert startRes.get().isOk(), "Error starting node " & startRes.get().error

  check:
    kernel.started == true

  # Default conf has p2pTcpPort=0, so the OS must have assigned a real port.
  var hasNonZeroTcp = false
  for a in kernel.switch.peerInfo.listenAddrs:
    let s = $a
    if ("/tcp/" in s) and not ("/tcp/0" in s):
      hasNonZeroTcp = true
  check hasNonZeroTcp

  ## Cleanup
  (await kernel.stop()).isOkOr:
    raiseAssert "failed to stop kernel: " & error

suite "Auto-port retry":
  asynctest "metrics binds on free TCP port, fails on taken":
    let taken = createStreamServer(initTAddress("127.0.0.1", Port(0)))
    defer:
      taken.stop()
      await taken.closeWait()
    let takenPort = taken.localAddress().port

    let freePort = block:
      let probe = createStreamServer(initTAddress("127.0.0.1", Port(0)))
      let p = probe.localAddress().port
      probe.stop()
      await probe.closeWait()
      p

    proc buildMetricsConf(port: Port): MetricsServerConf =
      var b = MetricsServerConfBuilder.init()
      b.withEnabled(true)
      b.withHttpPort(port)
      b.build().value.get()

    let failRes = await startMetricsServerAndLogging(buildMetricsConf(takenPort))
    check failRes.isErr()

    let okRes = await startMetricsServerAndLogging(buildMetricsConf(freePort))
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().server.close()

  asynctest "discv5 binds on free UDP port, fails on taken":
    proc dummyCb(
        transp: DatagramTransport, raddr: TransportAddress
    ): Future[void] {.async: (raises: []).} =
      discard

    let nodeKey = generateSecp256k1Key()
    let kernel = newTestWakuNode(nodeKey)
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    defer:
      (await kernel.stop()).isOkOr:
        raiseAssert "failed to stop kernel: " & error

    let takenUdp =
      newDatagramTransport(dummyCb, local = initTAddress("0.0.0.0", Port(0)))
    defer:
      await takenUdp.closeWait()
    let takenPort = takenUdp.localAddress().port

    let freePort = block:
      let probe =
        newDatagramTransport(dummyCb, local = initTAddress("0.0.0.0", Port(0)))
      let p = probe.localAddress().port
      await probe.closeWait()
      p

    proc buildDiscv5Conf(port: Port): Discv5Conf =
      var b = Discv5ConfBuilder.init()
      b.withEnabled(true)
      b.withUdpPort(port)
      b.build().value.get()

    let failRes = await setupAndStartDiscv5(
      kernel.enr,
      kernel.peerManager,
      buildDiscv5Conf(takenPort),
      @[],
      kernel.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
    )
    check failRes.isErr()

    let okRes = await setupAndStartDiscv5(
      kernel.enr,
      kernel.peerManager,
      buildDiscv5Conf(freePort),
      @[],
      kernel.rng,
      nodeKey,
      parseIpAddress("0.0.0.0"),
    )
    check okRes.isOk()
    if okRes.isOk():
      await okRes.get().stop()
