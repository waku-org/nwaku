{.used.}

import
  std/[sequtils],
  stew/results,
  stew/shims/net,
  chronos,
  chronicles,
  testutils/unittests,
  libp2p/crypto/crypto as libp2p_keys,
  eth/keys as eth_keys
import
  ../../waku/waku_core/topics,
  ../../waku/waku_enr,
  ../../waku/waku_discv5,
  ./testlib/common,
  ./testlib/wakucore,
  ./testlib/wakunode


proc newTestEnrRecord(privKey: libp2p_keys.PrivateKey,
                      extIp: string, tcpPort: uint16, udpPort: uint16,
                      flags = none(CapabilitiesBitfield)): waku_enr.Record =
  var builder = EnrBuilder.init(privKey)
  builder.withIpAddressAndPorts(
      ipAddr = some(ValidIpAddress.init(extIp)),
      tcpPort = some(Port(tcpPort)),
      udpPort = some(Port(udpPort)),
  )

  if flags.isSome():
    builder.withWakuCapabilities(flags.get())

  builder.build().tryGet()


proc newTestDiscv5(privKey: libp2p_keys.PrivateKey,
                       bindIp: string, tcpPort: uint16, udpPort: uint16,
                       record: waku_enr.Record,
                       bootstrapRecords = newSeq[waku_enr.Record]()): WakuDiscoveryV5 =
  let config = WakuDiscoveryV5Config(
      privateKey: eth_keys.PrivateKey(privKey.skkey),
      address: ValidIpAddress.init(bindIp),
      port: Port(udpPort),
      bootstrapRecords: bootstrapRecords,
  )

  let discv5 = WakuDiscoveryV5.new(rng(), config, some(record))

  return discv5


procSuite "Waku Discovery v5":
  asyncTest "find random peers":
    ## Given
    # Node 1
    let
      privKey1 =  generateSecp256k1Key()
      bindIp1 = "0.0.0.0"
      extIp1 = "127.0.0.1"
      tcpPort1 = 61500u16
      udpPort1 = 9000u16

    let record1 = newTestEnrRecord(
        privKey = privKey1,
        extIp = extIp1,
        tcpPort = tcpPort1,
        udpPort = udpPort1,
    )
    let node1 = newTestDiscv5(
        privKey = privKey1,
        bindIp = bindIp1,
        tcpPort = tcpPort1,
        udpPort = udpPort1,
        record = record1
    )

    # Node 2
    let
      privKey2 = generateSecp256k1Key()
      bindIp2 = "0.0.0.0"
      extIp2 = "127.0.0.1"
      tcpPort2 = 61502u16
      udpPort2 = 9002u16

    let record2 = newTestEnrRecord(
        privKey = privKey2,
        extIp = extIp2,
        tcpPort = tcpPort2,
        udpPort = udpPort2,
    )

    let node2 = newTestDiscv5(
        privKey = privKey2,
        bindIp = bindIp2,
        tcpPort = tcpPort2,
        udpPort = udpPort2,
        record = record2,
    )

    # Node 3
    let
      privKey3 = generateSecp256k1Key()
      bindIp3 = "0.0.0.0"
      extIp3 = "127.0.0.1"
      tcpPort3 = 61504u16
      udpPort3 = 9004u16

    let record3 = newTestEnrRecord(
        privKey = privKey3,
        extIp = extIp3,
        tcpPort = tcpPort3,
        udpPort = udpPort3,
    )

    let node3 = newTestDiscv5(
        privKey = privKey3,
        bindIp = bindIp3,
        tcpPort = tcpPort3,
        udpPort = udpPort3,
        record = record3,
        bootstrapRecords = @[record1, record2]
    )

    let res1 = node1.start()
    assert res1.isOk(), res1.error

    let res2 = node2.start()
    assert res2.isOk(), res2.error

    let res3 = node3.start()
    assert res3.isOk(), res3.error

    ## When
    let res = await node3.findRandomPeers()

    ## Then
    check:
      res.len >= 1

    ## Cleanup
    await allFutures(node1.stop(), node2.stop(), node3.stop())

  asyncTest "find random peers with predicate":
    ## Setup
    # Records
    let
      privKey1 =  generateSecp256k1Key()
      bindIp1 = "0.0.0.0"
      extIp1 = "127.0.0.1"
      tcpPort1 = 61500u16
      udpPort1 = 9000u16

    let record1 = newTestEnrRecord(
        privKey = privKey1,
        extIp = extIp1,
        tcpPort = tcpPort1,
        udpPort = udpPort1,
        flags = some(CapabilitiesBitfield.init(Capabilities.Relay))
    )

    let
      privKey2 = generateSecp256k1Key()
      bindIp2 = "0.0.0.0"
      extIp2 = "127.0.0.1"
      tcpPort2 = 61502u16
      udpPort2 = 9002u16

    let record2 = newTestEnrRecord(
        privKey = privKey2,
        extIp = extIp2,
        tcpPort = tcpPort2,
        udpPort = udpPort2,
        flags = some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store))
    )

    let
      privKey3 = generateSecp256k1Key()
      bindIp3 = "0.0.0.0"
      extIp3 = "127.0.0.1"
      tcpPort3 = 61504u16
      udpPort3 = 9004u16

    let record3 = newTestEnrRecord(
        privKey = privKey3,
        extIp = extIp3,
        tcpPort = tcpPort3,
        udpPort = udpPort3,
        flags = some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Filter))
    )

    let
      privKey4 = generateSecp256k1Key()
      bindIp4 = "0.0.0.0"
      extIp4 = "127.0.0.1"
      tcpPort4 = 61506u16
      udpPort4 = 9006u16

    let record4 = newTestEnrRecord(
        privKey = privKey4,
        extIp = extIp4,
        tcpPort = tcpPort4,
        udpPort = udpPort4,
        flags = some(CapabilitiesBitfield.init(Capabilities.Relay, Capabilities.Store))
    )


    # Nodes
    let node1 = newTestDiscv5(
        privKey = privKey1,
        bindIp = bindIp1,
        tcpPort = tcpPort1,
        udpPort = udpPort1,
        record = record1,
        bootstrapRecords = @[record2]
    )
    let node2 = newTestDiscv5(
        privKey = privKey2,
        bindIp = bindIp2,
        tcpPort = tcpPort2,
        udpPort = udpPort2,
        record = record2,
        bootstrapRecords = @[record3, record4]
    )

    let node3 = newTestDiscv5(
        privKey = privKey3,
        bindIp = bindIp3,
        tcpPort = tcpPort3,
        udpPort = udpPort3,
        record = record3
    )

    let node4 = newTestDiscv5(
        privKey = privKey4,
        bindIp = bindIp4,
        tcpPort = tcpPort4,
        udpPort = udpPort4,
        record = record4
    )

    # Start nodes' discoveryV5 protocols
    let res1 = node1.start()
    assert res1.isOk(), res1.error

    let res2 = node2.start()
    assert res2.isOk(), res2.error

    let res3 = node3.start()
    assert res3.isOk(), res3.error

    let res4 = node4.start()
    assert res4.isOk(), res4.error

    ## Given
    let recordPredicate: WakuDiscv5Predicate = proc(record: waku_enr.Record): bool =
          let typedRecord = record.toTyped()
          if typedRecord.isErr():
            return false

          let capabilities =  typedRecord.value.waku2
          if capabilities.isNone():
            return false

          return capabilities.get().supportsCapability(Capabilities.Store)


    ## When
    let peers = await node1.findRandomPeers(some(recordPredicate))

    ## Then
    check:
      peers.len >= 1
      peers.allIt(it.supportsCapability(Capabilities.Store))

    # Cleanup
    await allFutures(node1.stop(), node2.stop(), node3.stop(), node4.stop())

  asyncTest "get relayShards from topics":
    ## Given
    let mixedTopics = @["/waku/2/thisisatest", "/waku/2/rs/0/2", "/waku/2/rs/0/8"]
    let shardedTopics = @["/waku/2/rs/0/2", "/waku/2/rs/0/4", "/waku/2/rs/0/8"]
    let namedTopics = @["/waku/2/thisisatest", "/waku/2/atestthisis", "/waku/2/isthisatest"]
    let gibberish = @["aedyttydcb/uioasduyio", "jhdfsjhlsdfjhk/sadjhk", "khfsd/hjfdsgjh/dfs"]
    let empty: seq[string] = @[]

    let relayShards = RelayShards.init(0, @[uint16(2), uint16(4), uint16(8)]).expect("Valid Shards")

    ## When

    let mixedRes = topicsToRelayShards(mixedTopics)
    let shardedRes = topicsToRelayShards(shardedTopics)
    let namedRes = topicsToRelayShards(namedTopics)
    let gibberishRes = topicsToRelayShards(gibberish)
    let emptyRes = topicsToRelayShards(empty)

    ## Then
    assert mixedRes.isErr(), $mixedRes.value
    assert shardedRes.isOk(), shardedRes.error
    assert shardedRes.value.isSome()
    assert shardedRes.value.get() == relayShards, $shardedRes.value.get()
    assert namedRes.isOk(), namedRes.error
    assert namedRes.value.isNone(), $namedRes.value
    assert gibberishRes.isErr(), $gibberishRes.value
    assert emptyRes.isOk(), emptyRes.error
    assert emptyRes.value.isNone(), $emptyRes.value

  asyncTest "filter peer per static shard":
    ## Given
    let recordCluster21 = block:
      let
        enrSeqNum = 1u64
        enrPrivKey = generatesecp256k1key()

      let
        shardCluster: uint16 = 21
        shardIndices: seq[uint16] = @[1u16, 2u16, 5u16, 7u16, 9u16, 11u16]

      let shards = RelayShards.init(shardCluster, shardIndices).expect("Valid Shards")

      var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
      require builder.withWakuRelaySharding(shards).isOk()

      let recordRes = builder.build()
      require recordRes.isOk()
      recordRes.tryGet()

    let recordCluster22Indices1 = block:
      let
        enrSeqNum = 1u64
        enrPrivKey = generatesecp256k1key()

      let
        shardCluster: uint16 = 22
        shardIndices: seq[uint16] = @[2u16, 4u16, 5u16, 8u16, 10u16, 12u16]

      let shards = RelayShards.init(shardCluster, shardIndices).expect("Valid Shards")

      var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
      require builder.withWakuRelaySharding(shards).isOk()

      let recordRes = builder.build()
      require recordRes.isOk()
      recordRes.tryGet()

    let recordCluster22Indices2 = block:
      let
        enrSeqNum = 1u64
        enrPrivKey = generatesecp256k1key()

      let
        shardCluster: uint16 = 22
        shardIndices: seq[uint16] = @[1u16, 3u16, 6u16, 7u16, 9u16, 11u16]

      let shards = RelayShards.init(shardCluster, shardIndices).expect("Valid Shards")

      var builder = EnrBuilder.init(enrPrivKey, seqNum = enrSeqNum)
      require builder.withWakuRelaySharding(shards).isOk()

      let recordRes = builder.build()
      require recordRes.isOk()
      recordRes.tryGet()

    ## When
    let predicateCluster21Op = shardingPredicate(recordCluster21)
    require predicateCluster21Op.isSome()
    let predicateCluster21 = predicateCluster21Op.get()

    let predicateCluster22Op = shardingPredicate(recordCluster22Indices1)
    require predicateCluster22Op.isSome()
    let predicateCluster22 = predicateCluster22Op.get()

    ## Then
    check:
      predicateCluster21(recordCluster21) == true
      predicateCluster21(recordCluster22Indices1) == false
      predicateCluster21(recordCluster22Indices2) == false
      predicateCluster22(recordCluster21) == false
      predicateCluster22(recordCluster22Indices1) == true
      predicateCluster22(recordCluster22Indices2) == false

  asyncTest "update ENR from subscriptions":
    ## Given
    let
      shard1 = "/waku/2/rs/0/1"
      shard2 = "/waku/2/rs/0/2"
      shard3 = "/waku/2/rs/0/3"
      privKey =  generateSecp256k1Key()
      bindIp = "0.0.0.0"
      extIp = "127.0.0.1"
      tcpPort = 61500u16
      udpPort = 9000u16

    let record = newTestEnrRecord(
        privKey = privKey,
        extIp = extIp,
        tcpPort = tcpPort,
        udpPort = udpPort,
    )

    let node = newTestDiscv5(
        privKey = privKey,
        bindIp = bindIp,
        tcpPort = tcpPort,
        udpPort = udpPort,
        record = record
    )

    let res = node.start()
    assert res.isOk(), res.error

    let queue = newAsyncEventQueue[SubscriptionEvent](0)

    ## When
    asyncSpawn node.subscriptionsListener(queue)

    ## Then
    queue.emit((kind: PubsubSub, topic: shard1))
    queue.emit((kind: PubsubSub, topic: shard2))
    queue.emit((kind: PubsubSub, topic: shard3))

    await sleepAsync(1.seconds)

    check:
      node.protocol.localNode.record.containsShard(shard1) == true
      node.protocol.localNode.record.containsShard(shard2) == true
      node.protocol.localNode.record.containsShard(shard3) == true

    queue.emit((kind: PubsubSub, topic: shard1))
    queue.emit((kind: PubsubSub, topic: shard2))
    queue.emit((kind: PubsubSub, topic: shard3))

    await sleepAsync(1.seconds)

    check:
      node.protocol.localNode.record.containsShard(shard1) == true
      node.protocol.localNode.record.containsShard(shard2) == true
      node.protocol.localNode.record.containsShard(shard3) == true

    queue.emit((kind: PubsubUnsub, topic: shard1))
    queue.emit((kind: PubsubUnsub, topic: shard2))
    queue.emit((kind: PubsubUnsub, topic: shard3))

    await sleepAsync(1.seconds)

    check:
      node.protocol.localNode.record.containsShard(shard1) == false
      node.protocol.localNode.record.containsShard(shard2) == false
      node.protocol.localNode.record.containsShard(shard3) == false

    ## Cleanup
    await node.stop()


