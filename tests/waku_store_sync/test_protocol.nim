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
  ./sync_utils

suite "Waku Sync: 2 nodes recon":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var
    idsChannel {.threadvar.}: AsyncQueue[ID]
    wantsChannel {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]
    needsChannel {.threadvar.}: AsyncQueue[(PeerId, Fingerprint)]

  var server {.threadvar.}: SyncReconciliation
  var client {.threadvar.}: SyncReconciliation

  var serverPeerInfo {.threadvar.}: RemotePeerInfo
  var clientPeerInfo {.threadvar.}: RemotePeerInfo

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    idsChannel = newAsyncQueue[ID]()
    wantsChannel = newAsyncQueue[(PeerId, Fingerprint)]()
    needsChannel = newAsyncQueue[(PeerId, Fingerprint)]()

    server =
      await newTestWakuRecon(serverSwitch, idsChannel, wantsChannel, needsChannel)
    client =
      await newTestWakuRecon(clientSwitch, idsChannel, wantsChannel, needsChannel)

    serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    clientPeerInfo = clientSwitch.peerInfo.toRemotePeerInfo()

  asyncTeardown:
    await sleepAsync(10.milliseconds)

    await allFutures(server.stop(), client.stop())
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  asyncTest "sync 2 nodes both empty":
    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      idsChannel.len == 0
      wantsChannel.len == 0
      needsChannel.len == 0

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

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      needsChannel.contains((clientPeerInfo.peerId, hash1)) == true
      needsChannel.contains((clientPeerInfo.peerId, hash2)) == true
      needsChannel.contains((clientPeerInfo.peerId, hash3)) == true

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

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), res.error

    check:
      needsChannel.contains((serverPeerInfo.peerId, hash1)) == true
      needsChannel.contains((serverPeerInfo.peerId, hash2)) == true
      needsChannel.contains((serverPeerInfo.peerId, hash3)) == true

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

    var syncRes = await client.storeSynchronization(some(serverPeerInfo))
    assert syncRes.isOk(), $syncRes.error

    check:
      needsChannel.contains((serverPeerInfo.peerId, hash3))
      needsChannel.contains((clientPeerInfo.peerId, hash2))
      wantsChannel.contains((clientPeerInfo.peerId, hash3))
      wantsChannel.contains((serverPeerInfo.peerId, hash2))

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

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      wantsChannel.len == 0
      needsChannel.len == 0

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
      continue

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    check:
      wantsChannel.contains((serverPeerInfo.peerId, Fingerprint(diff))) == true
      needsChannel.contains((clientPeerInfo.peerId, Fingerprint(diff))) == true

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

    let res = await client.storeSynchronization(some(serverPeerInfo))
    assert res.isOk(), $res.error

    # timimg issue make it hard to match exact numbers
    check:
      wantsChannel.len > 900
      needsChannel.len > 900
