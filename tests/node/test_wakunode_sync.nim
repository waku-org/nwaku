{.used.}

import stew/shims/net as stewNet, testutils/unittests, chronos, libp2p/crypto/crypto

import
  ../../../waku/
    [node/waku_node, node/peer_manager, waku_core, waku_store, waku_archive, waku_sync],
  ../waku_store/store_utils,
  ../waku_archive/archive_utils,
  ../testlib/[wakucore, wakunode, testasync]

suite "Store Sync - End to End":
  var server {.threadvar.}: WakuNode
  var client {.threadvar.}: WakuNode

  asyncSetup:
    let timeOrigin = now()

    let messages =
      @[
        fakeWakuMessage(@[byte 00], ts = ts(-90, timeOrigin)),
        fakeWakuMessage(@[byte 01], ts = ts(-80, timeOrigin)),
        fakeWakuMessage(@[byte 02], ts = ts(-70, timeOrigin)),
        fakeWakuMessage(@[byte 03], ts = ts(-60, timeOrigin)),
        fakeWakuMessage(@[byte 04], ts = ts(-50, timeOrigin)),
        fakeWakuMessage(@[byte 05], ts = ts(-40, timeOrigin)),
        fakeWakuMessage(@[byte 06], ts = ts(-30, timeOrigin)),
        fakeWakuMessage(@[byte 07], ts = ts(-20, timeOrigin)),
        fakeWakuMessage(@[byte 08], ts = ts(-10, timeOrigin)),
        fakeWakuMessage(@[byte 09], ts = ts(00, timeOrigin)),
      ]

    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    let serverArchiveDriver = newArchiveDriverWithMessages(DefaultPubsubTopic, messages)
    let clientArchiveDriver = newArchiveDriverWithMessages(DefaultPubsubTopic, messages)

    let mountServerArchiveRes = server.mountArchive(serverArchiveDriver)
    let mountClientArchiveRes = client.mountArchive(clientArchiveDriver)

    assert mountServerArchiveRes.isOk()
    assert mountClientArchiveRes.isOk()

    await server.mountStore()
    await client.mountStore()

    client.mountStoreClient()
    server.mountStoreClient()

    let mountServerSync = server.mountWakuSync(
      maxFrameSize = 0,
      relayJitter = 0.seconds,
      syncInterval = 1.hours,
      enablePruning = false,
    )
    let mountClientSync = client.mountWakuSync(
      maxFrameSize = 0,
      syncInterval = 1.seconds,
      relayJitter = 0.seconds,
      enablePruning = false,
    )

    assert mountServerSync.isOk()
    assert mountClientSync.isOk()

    for msg in messages:
      server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)

    await allFutures(server.start(), client.start())

    await sleepAsync(chronos.milliseconds(500))

    let serverRemotePeerInfo = server.peerInfo.toRemotePeerInfo()
    let clientRemotePeerInfo = client.peerInfo.toRemotePeerInfo()

    client.peerManager.addServicePeer(serverRemotePeerInfo, WakuSyncCodec)
    server.peerManager.addServicePeer(clientRemotePeerInfo, WakuSyncCodec)

    client.peerManager.addServicePeer(serverRemotePeerInfo, WakuStoreCodec)
    server.peerManager.addServicePeer(clientRemotePeerInfo, WakuStoreCodec)

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  asyncTest "no message set differences":
    check:
      client.wakuSync.storageSize() == server.wakuSync.storageSize()

    await sleepAsync(1.seconds)

    check:
      client.wakuSync.storageSize() == server.wakuSync.storageSize()

  asyncTest "client message set differences":
    let msg = fakeWakuMessage(@[byte 10])

    client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
    await client.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    check:
      client.wakuSync.storageSize() != server.wakuSync.storageSize()

    await sleepAsync(1.seconds)

    check:
      client.wakuSync.storageSize() == server.wakuSync.storageSize()

  asyncTest "server message set differences":
    let msg = fakeWakuMessage(@[byte 10])

    server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
    await server.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    check:
      client.wakuSync.storageSize() != server.wakuSync.storageSize()

    await sleepAsync(1.seconds)

    check:
      client.wakuSync.storageSize() == server.wakuSync.storageSize()

suite "Waku Sync - Pruning":
  var server {.threadvar.}: WakuNode
  var client {.threadvar.}: WakuNode

  asyncSetup:
    let
      serverKey = generateSecp256k1Key()
      clientKey = generateSecp256k1Key()

    server = newTestWakuNode(serverKey, ValidIpAddress.init("0.0.0.0"), Port(0))
    client = newTestWakuNode(clientKey, ValidIpAddress.init("0.0.0.0"), Port(0))

    let serverArchiveDriver = newSqliteArchiveDriver()
    let clientArchiveDriver = newSqliteArchiveDriver()

    let mountServerArchiveRes = server.mountArchive(serverArchiveDriver)
    let mountClientArchiveRes = client.mountArchive(clientArchiveDriver)

    assert mountServerArchiveRes.isOk()
    assert mountClientArchiveRes.isOk()

    await server.mountStore()
    await client.mountStore()

    client.mountStoreClient()
    server.mountStoreClient()

    let mountServerSync = server.mountWakuSync(
      maxFrameSize = 0,
      relayJitter = 0.seconds,
      syncInterval = 1.hours,
      enablePruning = false,
    )
    let mountClientSync = client.mountWakuSync(
      maxFrameSize = 0,
      syncInterval = 1.seconds,
      relayJitter = 0.seconds,
      enablePruning = true,
    )

    assert mountServerSync.isOk()
    assert mountClientSync.isOk()

    await allFutures(server.start(), client.start())

    await sleepAsync(1.seconds)

  asyncTeardown:
    await allFutures(client.stop(), server.stop())

  asyncTest "pruning":
    for _ in 0 ..< 10:
      let msg = fakeWakuMessage()
      client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await client.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

      server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await server.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    await sleepAsync(1.seconds)

    for _ in 0 ..< 10:
      let msg = fakeWakuMessage()
      client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await client.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

      server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await server.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    await sleepAsync(1.seconds)

    for _ in 0 ..< 10:
      let msg = fakeWakuMessage()
      client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await client.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

      server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await server.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    await sleepAsync(1.seconds)

    for _ in 0 ..< 10:
      let msg = fakeWakuMessage()
      client.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await client.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

      server.wakuSync.ingessMessage(DefaultPubsubTopic, msg)
      await server.wakuArchive.handleMessage(DefaultPubsubTopic, msg)

    await sleepAsync(1.seconds)

    check:
      client.wakuSync.storageSize() == 10
