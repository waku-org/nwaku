{.used.}

import
  std/[options, sets, random, math],
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  stew/byteutils

import
  ../../waku/[
    node/peer_manager,
    waku_core,
    waku_core/message,
    waku_core/message/digest,
    waku_store_sync,
    waku_store_sync/storage/range_processing,
  ],
  ../testlib/[wakucore, testasync],
  ../waku_archive/archive_utils,
  ./sync_utils

suite "Waku Sync: reconciliation":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var
    idsChannel {.threadvar.}: AsyncQueue[ID]
    localWants {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]
    remoteNeeds {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]

  var server {.threadvar.}: SyncReconciliation
  var client {.threadvar.}: SyncReconciliation

  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    idsChannel = newAsyncQueue[ID]()
    localWants = newAsyncQueue[(PeerId, Fingerprint)]()
    remoteNeeds = newAsyncQueue[(PeerId, Fingerprint)]()

    server = await newTestWakuRecon(serverSwitch, idsChannel, localWants, remoteNeeds)
    client = await newTestWakuRecon(clientSwitch, idsChannel, localWants, remoteNeeds)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await allFutures(server.stop(), client.stop())
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "sync 2 nodes both empty":
    check:
      idsChannel.len == 0
      localWants.len == 0
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      idsChannel.len == 0
      localWants.len == 0
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes empty client full server":
    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3)

    server.messageIngress(hash1, msg1)
    server.messageIngress(hash2, msg2)
    server.messageIngress(hash3, msg3)

    check:
      remoteNeeds.contains((clientPeerInfo.peerId, hash1)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.contains((clientPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash3)) == true

  asyncTest "sync 2 nodes full client empty server":
    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3)

    client.messageIngress(hash1, msg1)
    client.messageIngress(hash2, msg2)
    client.messageIngress(hash3, msg3)

    check:
      remoteNeeds.contains((serverPeerInfo.peerId, hash1)) == false
      remoteNeeds.contains((serverPeerInfo.peerId, hash2)) == false
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      remoteNeeds.contains((serverPeerInfo.peerId, hash1)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash2)) == true
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true

  asyncTest "sync 2 nodes different hashes":
    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      msg3 = fakeWakuMessage(ts = now() + 2, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(DefaultPubsubTopic, msg2)
      hash3 = computeMessageHash(DefaultPubsubTopic, msg3)

    server.messageIngress(hash1, msg1)
    server.messageIngress(hash2, msg2)
    client.messageIngress(hash1, msg1)
    client.messageIngress(hash3, msg3)

    check:
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == false
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == false
      localWants.contains((clientPeerInfo.peerId, hash3)) == false
      localWants.contains((serverPeerInfo.peerId, hash2)) == false

    var syncRes = await client.storeSynchronization(some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      remoteNeeds.contains((serverPeerInfo.peerId, hash3)) == true
      remoteNeeds.contains((clientPeerInfo.peerId, hash2)) == true
      localWants.contains((clientPeerInfo.peerId, hash3)) == true
      localWants.contains((serverPeerInfo.peerId, hash2)) == true

  asyncTest "sync 2 nodes same hashes":
    let
      msg1 = fakeWakuMessage(ts = now(), contentTopic = DefaultContentTopic)
      msg2 = fakeWakuMessage(ts = now() + 1, contentTopic = DefaultContentTopic)
      hash1 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)
      hash2 = computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)

    server.messageIngress(hash1, msg1)
    client.messageIngress(hash1, msg1)
    server.messageIngress(hash2, msg2)
    client.messageIngress(hash2, msg2)

    check:
      localWants.len == 0
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      localWants.len == 0
      remoteNeeds.len == 0

  asyncTest "sync 2 nodes 100K msgs 1 diff":
    let msgCount = 100_000
    var diffIndex = rand(msgCount)
    var diff: WakuMessageHash

    # the sync window is 1 hour, spread msg equally in that time
    let timeSlice = calculateTimeRange()
    let timeWindow = int64(timeSlice.b) - int64(timeSlice.a)
    let (part, _) = divmod(timeWindow, 100_000)

    var timestamp = timeSlice.a

    for i in 0 ..< msgCount:
      let msg = fakeWakuMessage(ts = timestamp, contentTopic = DefaultContentTopic)
      let hash = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(hash, msg)

      if i != diffIndex:
        client.messageIngress(hash, msg)
      else:
        diff = hash

      timestamp += Timestamp(part)

    check:
      localWants.contains((serverPeerInfo.peerId, Fingerprint(diff))) == false
      remoteNeeds.contains((clientPeerInfo.peerId, Fingerprint(diff))) == false

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      localWants.contains((serverPeerInfo.peerId, Fingerprint(diff))) == true
      remoteNeeds.contains((clientPeerInfo.peerId, Fingerprint(diff))) == true

  asyncTest "sync 2 nodes 10K msgs 1K diffs":
    let msgCount = 10_000
    var diffCount = 1_000

    var diffMsgHashes: HashSet[WakuMessageHash]
    var randIndexes: HashSet[int]

    # Diffs
    for i in 0 ..< diffCount:
      var randInt = rand(0 ..< msgCount)

      #make sure we actually have the right number of diffs
      while randInt in randIndexes:
        randInt = rand(0 ..< msgCount)

      randIndexes.incl(randInt)

    # sync window is 1 hour, spread msg equally in that time
    let timeSlice = calculateTimeRange()
    let timeWindow = int64(timeSlice.b) - int64(timeSlice.a)
    let (part, _) = divmod(timeWindow, 100_000)

    var timestamp = timeSlice.a

    for i in 0 ..< msgCount:
      let
        msg = fakeWakuMessage(ts = timestamp, contentTopic = DefaultContentTopic)
        hash = computeMessageHash(DefaultPubsubTopic, msg)

      server.messageIngress(hash, msg)

      if i in randIndexes:
        diffMsgHashes.incl(hash)
      else:
        client.messageIngress(hash, msg)

      timestamp += Timestamp(part)
      continue

    check:
      localWants.len == 0
      remoteNeeds.len == 0

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    # timimg issue make it hard to match exact numbers
    check:
      localWants.len > 900
      remoteNeeds.len > 900

suite "Waku Sync: transfer":
  var
    serverSwitch {.threadvar.}: Switch
    clientSwitch {.threadvar.}: Switch

  var
    serverArchive {.threadvar.}: WakuArchive
    clientArchive {.threadvar.}: WakuArchive

  var
    serverIds {.threadvar.}: AsyncQueue[ID]
    serverLocalWants {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]
    serverRemoteNeeds {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]
    clientIds {.threadvar.}: AsyncQueue[ID]
    clientLocalWants {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]
    clientRemoteNeeds {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]

  var
    server {.threadvar.}: SyncTransfer
    client {.threadvar.}: SyncTransfer

  var
    serverPeerInfo {.threadvar.}: RemotePeerInfo
    clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverDriver = newSqliteArchiveDriver()
    let clientDriver = newSqliteArchiveDriver()

    serverArchive = newWakuArchive(serverDriver)
    clientArchive = newWakuArchive(clientDriver)

    let
      serverPeerManager = PeerManager.new(serverSwitch)
      clientPeerManager = PeerManager.new(clientSwitch)

    serverIds = newAsyncQueue[ID]()
    serverLocalWants = newAsyncQueue[(PeerId, Fingerprint)]()
    serverRemoteNeeds = newAsyncQueue[(PeerId, Fingerprint)]()

    server = SyncTransfer.new(
      peerManager = serverPeerManager,
      wakuArchive = serverArchive,
      idsTx = serverIds,
      wantsRx = serverLocalWants,
      needsRx = serverRemoteNeeds,
    )

    clientIds = newAsyncQueue[ID]()
    clientLocalWants = newAsyncQueue[(PeerId, Fingerprint)]()
    clientRemoteNeeds = newAsyncQueue[(PeerId, Fingerprint)]()

    client = SyncTransfer.new(
      peerManager = clientPeerManager,
      wakuArchive = clientArchive,
      idsTx = clientIds,
      wantsRx = clientLocalWants,
      needsRx = clientRemoteNeeds,
    )

    server.start()
    client.start()

    serverSwitch.mount(server)
    clientSwitch.mount(client)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await sleepAsync(10.milliseconds)

    await allFutures(server.stopWait(), client.stopWait())
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "transfer 1 message":
    let msg = fakeWakuMessage()
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    let msgs = @[msg]

    serverArchive.put(DefaultPubsubTopic, msgs)

    # add server info and msg hash to client want channel
    let want = (serverPeerInfo.peerId, hash)
    clientLocalWants.add(want)

    # add client info and msg hash to server need channel
    let need = (clientPeerInfo.peerId, hash)
    serverRemoteNeeds.add(need)

    # give time for transfer to happen
    await sleepAsync(10.miliseconds)

    var query = ArchiveQuery()
    query.includeData = true
    query.hashes = @[hash]

    let res = await clientArchive.findMessages(query)
    assert res.isOk(), $res.error

    let recvMsg = response.messages[0]

    check:
      msg == recvMsg
