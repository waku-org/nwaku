{.used.}

import
  std/[net, sequtils, strutils],
  results,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto

import
  logos_delivery/kernel/[
    api/kernel_lifecycle,
    peer_manager/peer_manager,
    subscription_manager,
    base/topics/content_topic,
    base/topics/pubsub_topic,
    base/message,
    base/peers,
    archive/driver,
    archive/retention_policy,
    archive/archive_metrics,
    archive/retention_policy/retention_policy_time,
    protocols/store_sync/reconciliation,
  ],
  ../waku_relay/utils,
  ../waku_archive/archive_utils,
  ../waku_store_sync/sync_utils,
  ../testlib/wakucore,
  ../testlib/wakunode,
  ../testlib/testasync
const
  listenIp = parseIpAddress("0.0.0.0")
  listenPort = Port(0)

proc newStoreSyncNode(
    driver: ArchiveDriver,
    retentionPolicies: seq[RetentionPolicy] = @[],
    storeSyncRelayJitter: uint32 = 0,
    maxMessageSize: int = int(DefaultMaxWakuMessageSize),
    quicEnabled = true,
): Future[Kernel] {.async.} =
  ## A store node whose sync interval is long enough that only the test starts sessions.
  let node = newTestWakuNode(
    generateSecp256k1Key(), listenIp, listenPort, quicEnabled = quicEnabled
  )
  node.mountArchive(driver, retentionPolicies).isOkOr:
    raiseAssert error
  (
    await node.mountStoreSync(
      DefaultClusterId,
      @[DefaultShardId],
      @[],
      storeSyncRange = 3600,
      storeSyncInterval = 300,
      storeSyncRelayJitter = storeSyncRelayJitter,
      maxMessageSize = maxMessageSize,
    )
  ).isOkOr:
    raiseAssert error
  return node

proc syncWith(node, peer: Kernel): Future[Result[void, string]] {.async.} =
  return await node.protocols.storeReconciliation.storeSynchronization(
    Opt.some(peer.switch.peerInfo.toRemotePeerInfo())
  )

suite "Waku Store Sync - End to End":
  var nodes {.threadvar.}: seq[Kernel]

  asyncTeardown:
    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "A node syncs what its peer's archive held before store sync was mounted":
    # Given a node whose archive already holds messages, and an empty node
    let
      msgs = @[
        fakeWakuMessage(@[byte 0]),
        fakeWakuMessage(@[byte 1]),
        fakeWakuMessage(@[byte 2]),
      ]
      hashes = msgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      server = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, msgs)
      )
      client = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[server, client]
    await allFutures(nodes.mapIt(it.start()))

    # When the empty node syncs with it
    let res = await client.syncWith(server)

    # Then the empty node's archive holds the messages
    check res.isOk()
    checkUntilTimeout:
      await client.protocols.archive.holdsMessages(hashes)

  asyncTest "A message received through store sync is synced to the next peer":
    # Given a message only node A holds
    let
      msg = fakeWakuMessage()
      hash = computeMessageHash(DefaultPubsubTopic, msg)
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, @[msg])
      )
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeC = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB, nodeC]
    await allFutures(nodes.mapIt(it.start()))

    # When B syncs with A, then C with B
    let resB = await nodeB.syncWith(nodeA)
    check resB.isOk()
    checkUntilTimeout:
      await nodeB.protocols.archive.holdsMessages(@[hash])

    let resC = await nodeC.syncWith(nodeB)

    # Then C's archive holds the message
    check resC.isOk()
    checkUntilTimeout:
      await nodeC.protocols.archive.holdsMessages(@[hash])

  asyncTest "One session gives two relay nodes each other's messages":
    # Given two relay nodes that each archived their own messages while not connected
    let
      nodeA = await newStoreSyncNode(newSqliteArchiveDriver())
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    await allFutures(nodes.mapIt(it.mountRelay()))
    await allFutures(nodes.mapIt(it.start()))
    for node in nodes:
      node.subscribe((kind: PubsubSub, topic: DefaultPubsubTopic), noopRawHandler()).isOkOr:
        raiseAssert error

    let
      msgsA = @[
        fakeWakuMessage(@[byte 0]),
        fakeWakuMessage(@[byte 1]),
        fakeWakuMessage(@[byte 2]),
      ]
      msgsB = @[
        fakeWakuMessage(@[byte 3]),
        fakeWakuMessage(@[byte 4]),
        fakeWakuMessage(@[byte 5]),
      ]
      hashesA = msgsA.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      hashesB = msgsB.mapIt(computeMessageHash(DefaultPubsubTopic, it))

    # With no peer the publish fails, after the node's own handler archived the message.
    for msg in msgsA:
      discard await nodeA.publish(Opt.some(DefaultPubsubTopic), msg)
    for msg in msgsB:
      discard await nodeB.publish(Opt.some(DefaultPubsubTopic), msg)
    checkUntilTimeout:
      await nodeA.protocols.archive.holdsMessages(hashesA)
      await nodeB.protocols.archive.holdsMessages(hashesB)

    let syncInsertsBefore = insertCount(syncIngress)

    # When they connect and A syncs with B
    await nodeA.connectToNodes(@[nodeB.switch.peerInfo.toRemotePeerInfo()])
    let res = await nodeA.syncWith(nodeB)

    # Then both archives hold all six messages, each one a node lacked written by sync
    check res.isOk()
    checkUntilTimeout:
      await nodeA.protocols.archive.holdsMessages(hashesA & hashesB)
      await nodeB.protocols.archive.holdsMessages(hashesA & hashesB)
    check insertCount(syncIngress) == syncInsertsBefore + 6

  asyncTest "The sync range is clamped to the archive's time retention":
    # Given a node whose time retention is shorter than the sync range plus jitter
    let node = newTestWakuNode(generateSecp256k1Key(), listenIp, listenPort)
    node.mountArchive(
      newSqliteArchiveDriver(), @[RetentionPolicy(TimeRetentionPolicy.new(1800))]
    ).isOkOr:
      raiseAssert error
    nodes = @[node]

    # When store sync is mounted with a 3600 s range and a 20 s relay jitter
    (
      await node.mountStoreSync(
        DefaultClusterId,
        @[DefaultShardId],
        @[],
        storeSyncRange = 3600,
        storeSyncInterval = 300,
        storeSyncRelayJitter = 20,
        maxMessageSize = int(DefaultMaxWakuMessageSize),
      )
    ).isOkOr:
      raiseAssert error
    (await node.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    # Then the effective range is the retention minus the jitter
    check node.protocols.storeReconciliation.getEffectiveSyncRange() == 1780.seconds

  asyncTest "The sync range stays as configured without a time retention":
    let node = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[node]
    (await node.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    check node.protocols.storeReconciliation.getEffectiveSyncRange() == 3600.seconds

  asyncTest "A peer with a longer sync range does not push messages older than the node's window":
    # Given a node whose window is [now - 1800 s, now - 20 s], and a peer with the
    # default 3600 s range holding a message older than that window and one inside it
    let
      oldMsg = fakeWakuMessage(@[byte 0], ts = now() - 2000.seconds.nanos)
      recentMsg = fakeWakuMessage(@[byte 1], ts = now() - 100.seconds.nanos)
      oldHash = computeMessageHash(DefaultPubsubTopic, oldMsg)
      recentHash = computeMessageHash(DefaultPubsubTopic, recentMsg)
      node = await newStoreSyncNode(
        newSqliteArchiveDriver(),
        @[RetentionPolicy(TimeRetentionPolicy.new(1800))],
        storeSyncRelayJitter = 20,
      )
      peer = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, @[oldMsg, recentMsg])
      )
    nodes = @[node, peer]
    await allFutures(nodes.mapIt(it.start()))

    let syncInsertsBefore = insertCount(syncIngress)

    # When the peer starts a session with the node
    let res = await peer.syncWith(node)

    # Then the node's archive gets the recent message only
    check res.isOk()
    checkUntilTimeout:
      await node.protocols.archive.holdsMessages(@[recentHash])
    check:
      not await node.protocols.archive.holdsMessages(@[oldHash])
      insertCount(syncIngress) == syncInsertsBefore + 1

  asyncTest "Nodes with a raised max message size sync a message above the default read limit":
    # Given two nodes with a 200 KiB max message size, one holding a message that is
    # above the default read limit (150 KiB + 64 KiB) but within theirs, and three small ones
    let
      bigMsg = fakeWakuMessage(newSeq[byte](230_000), ts = now() - 4.seconds.nanos)
      smallMsgs = @[
        fakeWakuMessage(@[byte 0], ts = now() - 3.seconds.nanos),
        fakeWakuMessage(@[byte 1], ts = now() - 2.seconds.nanos),
        fakeWakuMessage(@[byte 2], ts = now() - 1.seconds.nanos),
      ]
      msgs = @[bigMsg] & smallMsgs
      hashes = msgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, msgs),
        maxMessageSize = 200 * 1024,
      )
      nodeB =
        await newStoreSyncNode(newSqliteArchiveDriver(), maxMessageSize = 200 * 1024)
    nodes = @[nodeA, nodeB]
    await allFutures(nodes.mapIt(it.start()))

    # When B syncs with A
    let res = await nodeB.syncWith(nodeA)

    # Then B's archive holds all four messages
    check res.isOk()
    checkUntilTimeout:
      await nodeB.protocols.archive.holdsMessages(hashes)

  asyncTest "Over TCP, a peer with the default limit refuses the large messages and a third peer still gets everything":
    # Given a 200 KiB node holding two messages above the default read limit and a small
    # one, an empty peer at the default limit and an empty 200 KiB peer, all over TCP
    let
      bigMsgs = @[
        fakeWakuMessage(newSeq[byte](230_000), ts = now() - 3.seconds.nanos),
        fakeWakuMessage(newSeq[byte](230_000), ts = now() - 2.seconds.nanos),
      ]
      smallMsg = fakeWakuMessage(@[byte 0], ts = now() - 1.seconds.nanos)
      bigHashes = bigMsgs.mapIt(computeMessageHash(DefaultPubsubTopic, it))
      smallHash = computeMessageHash(DefaultPubsubTopic, smallMsg)
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, bigMsgs & @[smallMsg]),
        maxMessageSize = 200 * 1024,
        quicEnabled = false,
      )
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver(), quicEnabled = false)
      nodeC = await newStoreSyncNode(
        newSqliteArchiveDriver(), maxMessageSize = 200 * 1024, quicEnabled = false
      )
    nodes = @[nodeA, nodeB, nodeC]
    await allFutures(nodes.mapIt(it.start()))

    # When B syncs with A, then C syncs with A
    let resB = await nodeB.syncWith(nodeA)
    let resC = await nodeC.syncWith(nodeA)

    # Then B holds the small message only and C holds all three
    check:
      resB.isOk()
      resC.isOk()
    checkUntilTimeout:
      await nodeB.protocols.archive.holdsMessages(@[smallHash])
      await nodeC.protocols.archive.holdsMessages(bigHashes & @[smallHash])
    for hash in bigHashes:
      check not await nodeB.protocols.archive.holdsMessages(@[hash])

  asyncTest "A node stopped while its store sync transfer writes to a peer over TCP completes its stop":
    # Given a node that archived three hundred 100 KB messages, and a peer connected to it over TCP
    let
      msgs = toSeq(0 ..< 300).mapIt(fakeWakuMessage(newSeq[byte](100_000)))
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, msgs)
      )
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    await allFutures(nodes.mapIt(it.start()))
    check await nodeB.peerManager.connectPeer(
      RemotePeerInfo.init(
        nodeA.peerInfo.peerId, nodeA.peerInfo.addrs.filterIt("/quic-v1" notin $it)
      )
    )

    let sentBefore = transferCount(TransferDirection.Sent)

    # When the peer syncs with it, and the node is stopped once its transfer has sent a message
    let res = await nodeB.syncWith(nodeA)
    check res.isOk()
    checkUntilTimeoutCustom(10.seconds, 1.milliseconds):
      transferCount(TransferDirection.Sent) > sentBefore
    let stopping = nodeA.stop()

    # Then the stop completes before the node sent every message
    check:
      await stopping.join().withTimeout(3.seconds)
      transferCount(TransferDirection.Sent) < sentBefore + float64(msgs.len)
    nodes = @[nodeB]

  asyncTest "A node stopped while its store sync transfer writes to a peer over QUIC completes its stop":
    # Given a node that archived three hundred 100 KB messages, and a peer connected to it over QUIC
    let
      msgs = toSeq(0 ..< 300).mapIt(fakeWakuMessage(newSeq[byte](100_000)))
      nodeA = await newStoreSyncNode(
        await newArchiveDriverWithMessages(DefaultPubsubTopic, msgs)
      )
      nodeB = await newStoreSyncNode(newSqliteArchiveDriver())
    nodes = @[nodeA, nodeB]
    await allFutures(nodes.mapIt(it.start()))
    check await nodeB.peerManager.connectPeer(
      RemotePeerInfo.init(
        nodeA.peerInfo.peerId, nodeA.peerInfo.addrs.filterIt("/quic-v1" in $it)
      )
    )

    let sentBefore = transferCount(TransferDirection.Sent)

    # When the peer syncs with it, and the node is stopped once its transfer has sent a message
    let res = await nodeB.syncWith(nodeA)
    check res.isOk()
    checkUntilTimeoutCustom(10.seconds, 1.milliseconds):
      transferCount(TransferDirection.Sent) > sentBefore
    let stopping = nodeA.stop()

    # Then the stop completes before the node sent every message
    check:
      await stopping.join().withTimeout(3.seconds)
      transferCount(TransferDirection.Sent) < sentBefore + float64(msgs.len)
    nodes = @[nodeB]
