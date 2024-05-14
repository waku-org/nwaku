{.used.}

import
  std/[options, sets],
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  stew/byteutils,
  std/random

import
  ../../waku/[
    node/peer_manager,
    waku_core,
    waku_core/message/digest,
    waku_sync,
    waku_sync/raw_bindings,
  ],
  ../testlib/[wakucore, testasync],
  ./sync_utils

random.randomize()

suite "Waku Sync":
  var serverSwitch {.threadvar.}: Switch
  var clientSwitch {.threadvar.}: Switch

  var server {.threadvar.}: WakuSync
  var client {.threadvar.}: WakuSync

  var serverPeerInfo {.threadvar.}: Option[RemotePeerInfo]

  asyncSetup:
    serverSwitch = newTestSwitch()
    clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    server = await newTestWakuSync(serverSwitch)
    client = await newTestWakuSync(clientSwitch)

    serverPeerInfo = some(serverSwitch.peerInfo.toRemotePeerInfo())

  asyncTeardown:
    await sleepAsync(10.milliseconds)

    await allFutures(server.stop(), client.stop())
    await allFutures(serverSwitch.stop(), clientSwitch.stop())

  suite "Protocol":
    asyncTest "sync 2 nodes both empty":
      let hashes = await client.sync(serverPeerInfo)
      assert hashes.isOk(), hashes.error
      check:
        hashes.value[0].len == 0

    asyncTest "sync 2 nodes empty client full server":
      let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)

      server.ingessMessage(DefaultPubsubTopic, msg1)
      server.ingessMessage(DefaultPubsubTopic, msg2)
      server.ingessMessage(DefaultPubsubTopic, msg3)

      var hashes = await client.sync(serverPeerInfo)

      assert hashes.isOk(), hashes.error
      check:
        hashes.value[0].len == 3
        computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1) in hashes.value[0]
        computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2) in hashes.value[0]
        computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3) in hashes.value[0]

    asyncTest "sync 2 nodes full client empty server":
      let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)

      client.ingessMessage(DefaultPubsubTopic, msg1)
      client.ingessMessage(DefaultPubsubTopic, msg2)
      client.ingessMessage(DefaultPubsubTopic, msg3)

      var hashes = await client.sync(serverPeerInfo)
      assert hashes.isOk(), hashes.error
      check:
        hashes.value[0].len == 0

    asyncTest "sync 2 nodes different hashes":
      let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)

      server.ingessMessage(DefaultPubsubTopic, msg1)
      client.ingessMessage(DefaultPubsubTopic, msg1)
      server.ingessMessage(DefaultPubsubTopic, msg2)

      var syncRes = await client.sync(serverPeerInfo)

      check:
        syncRes.isOk()

      var hashes = syncRes.get()

      check:
        hashes[0].len == 1
        hashes[0][0] == computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)

      #Assuming message is fetched from peer
      client.ingessMessage(DefaultPubsubTopic, msg2)

      syncRes = await client.sync(serverPeerInfo)

      check:
        syncRes.isOk()

      hashes = syncRes.get()

      check:
        hashes[0].len == 0

    asyncTest "sync 2 nodes same hashes":
      let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)

      server.ingessMessage(DefaultPubsubTopic, msg1)
      client.ingessMessage(DefaultPubsubTopic, msg1)
      server.ingessMessage(DefaultPubsubTopic, msg2)
      client.ingessMessage(DefaultPubsubTopic, msg2)

      let hashes = await client.sync(serverPeerInfo)
      assert hashes.isOk(), $hashes.error
      check:
        hashes.value[0].len == 0

    asyncTest "sync 2 nodes 100K msgs":
      var i = 0
      let msgCount = 100000
      var diffIndex = rand(msgCount)
      var diffMsg: WakuMessage
      while i < msgCount:
        let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
        if i != diffIndex:
          client.ingessMessage(DefaultPubsubTopic, msg)
        else:
          diffMsg = msg
        server.ingessMessage(DefaultPubsubTopic, msg)
        i += 1

      let hashes = await client.sync(serverPeerInfo)
      assert hashes.isOk(), $hashes.error

      check:
        hashes.value[0].len == 1
        hashes.value[0][0] == computeMessageHash(DefaultPubsubTopic, diffMsg)

    asyncTest "sync 2 nodes 100K msgs 10K diffs":
      var i = 0
      let msgCount = 100000
      var diffCount = 10000

      var diffMsgHashes: seq[WakuMessageHash]
      var randIndexes: seq[int]
      while i < diffCount:
        let randInt = rand(msgCount)
        if randInt in randIndexes:
          continue
        randIndexes.add(randInt)
        i += 1

      i = 0
      var tmpDiffCnt = diffCount
      while i < msgCount:
        let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
        if tmpDiffCnt > 0 and i in randIndexes:
          diffMsgHashes.add(computeMessageHash(DefaultPubsubTopic, msg))
          tmpDiffCnt = tmpDiffCnt - 1
        else:
          client.ingessMessage(DefaultPubsubTopic, msg)

        server.ingessMessage(DefaultPubsubTopic, msg)
        i += 1

      let hashes = await client.sync(serverPeerInfo)
      assert hashes.isOk(), $hashes.error

      check:
        hashes.value[0].len == diffCount
        toHashSet(hashes.value[0]) == toHashSet(diffMsgHashes)

    asyncTest "sync 3 nodes 2 client 1 server":
      ## Setup
      let client2Switch = newTestSwitch()
      await client2Switch.start()
      let client2 = await newTestWakuSync(client2Switch)

      let msgCount = 10000
      var i = 0

      while i < msgCount:
        i += 1
        let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
        if i mod 2 == 0:
          client2.ingessMessage(DefaultPubsubTopic, msg)
        else:
          client.ingessMessage(DefaultPubsubTopic, msg)
        server.ingessMessage(DefaultPubsubTopic, msg)

      let fut1 = client.sync(serverPeerInfo)
      let fut2 = client2.sync(serverPeerInfo)
      waitFor allFutures(fut1, fut2)

      let hashes1 = fut1.read()
      let hashes2 = fut2.read()

      assert hashes1.isOk(), $hashes1.error
      assert hashes2.isOk(), $hashes2.error

      check:
        hashes1.value[0].len == int(msgCount / 2)
        hashes2.value[0].len == int(msgCount / 2)

      await client2.stop()
      await client2Switch.stop()

    asyncTest "sync 6 nodes varying sync diffs":
      ## Setup
      let
        client2Switch = newTestSwitch()
        client3Switch = newTestSwitch()
        client4Switch = newTestSwitch()
        client5Switch = newTestSwitch()

      await allFutures(
        client2Switch.start(),
        client3Switch.start(),
        client4Switch.start(),
        client5Switch.start(),
      )

      let
        client2 = await newTestWakuSync(client2Switch)
        client3 = await newTestWakuSync(client3Switch)
        client4 = await newTestWakuSync(client4Switch)
        client5 = await newTestWakuSync(client5Switch)

      let msgCount = 100000
      var i = 0

      while i < msgCount:
        let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
        if i < msgCount - 1:
          client.ingessMessage(DefaultPubsubTopic, msg)
        if i < msgCount - 10:
          client2.ingessMessage(DefaultPubsubTopic, msg)
        if i < msgCount - 100:
          client3.ingessMessage(DefaultPubsubTopic, msg)
        if i < msgCount - 1000:
          client4.ingessMessage(DefaultPubsubTopic, msg)
        if i < msgCount - 10000:
          client5.ingessMessage(DefaultPubsubTopic, msg)
        server.ingessMessage(DefaultPubsubTopic, msg)
        i += 1

      var timeBefore = getNowInNanosecondTime()
      let hashes1 = await client.sync(serverPeerInfo)
      var timeAfter = getNowInNanosecondTime()
      var syncTime = (timeAfter - timeBefore)
      debug "sync time in seconds", msgsTotal = msgCount, diff = 1, syncTime = syncTime
      assert hashes1.isOk(), $hashes1.error
      check:
        hashes1.value[0].len == 1

      timeBefore = getNowInNanosecondTime()
      let hashes2 = await client2.sync(serverPeerInfo)
      timeAfter = getNowInNanosecondTime()
      syncTime = (timeAfter - timeBefore)
      debug "sync time in seconds", msgsTotal = msgCount, diff = 10, syncTime = syncTime
      assert hashes2.isOk(), $hashes2.error
      check:
        hashes2.value[0].len == 10

      timeBefore = getNowInNanosecondTime()
      let hashes3 = await client3.sync(serverPeerInfo)
      timeAfter = getNowInNanosecondTime()
      syncTime = (timeAfter - timeBefore)
      debug "sync time in seconds",
        msgsTotal = msgCount, diff = 100, syncTime = syncTime
      assert hashes3.isOk(), $hashes3.error
      check:
        hashes3.value[0].len == 100

      timeBefore = getNowInNanosecondTime()
      let hashes4 = await client4.sync(serverPeerInfo)
      timeAfter = getNowInNanosecondTime()
      syncTime = (timeAfter - timeBefore)
      debug "sync time in seconds",
        msgsTotal = msgCount, diff = 1000, syncTime = syncTime
      assert hashes4.isOk(), $hashes4.error
      check:
        hashes4.value[0].len == 1000

      timeBefore = getNowInNanosecondTime()
      let hashes5 = await client5.sync(serverPeerInfo)
      timeAfter = getNowInNanosecondTime()
      syncTime = (timeAfter - timeBefore)
      debug "sync time in seconds",
        msgsTotal = msgCount, diff = 10000, syncTime = syncTime
      assert hashes5.isOk(), $hashes5.error
      check:
        hashes5.value[0].len == 10000

      await allFutures(client2.stop(), client3.stop(), client4.stop(), client5.stop())
      await allFutures(
        client2Switch.stop(),
        client3Switch.stop(),
        client4Switch.stop(),
        client5Switch.stop(),
      )

    asyncTest "sync 3 nodes cyclic":
      let
        node1Switch = newTestSwitch()
        node2Switch = newTestSwitch()
        node3Switch = newTestSwitch()

      await allFutures(node1Switch.start(), node2Switch.start(), node3Switch.start())

      let node1PeerInfo = some(node1Switch.peerInfo.toRemotePeerInfo())
      let node2PeerInfo = some(node2Switch.peerInfo.toRemotePeerInfo())
      let node3PeerInfo = some(node3Switch.peerInfo.toRemotePeerInfo())

      let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let hash1 = computeMessageHash(DefaultPubsubTopic, msg1)
      let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let hash2 = computeMessageHash(DefaultPubsubTopic, msg2)
      let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)
      let hash3 = computeMessageHash(DefaultPubsubTopic, msg3)

      let
        node1 = await newTestWakuSync(node1Switch)
        node2 = await newTestWakuSync(node2Switch)
        node3 = await newTestWakuSync(node3Switch)

      node1.ingessMessage(DefaultPubsubTopic, msg1)
      node2.ingessMessage(DefaultPubsubTopic, msg1)
      node2.ingessMessage(DefaultPubsubTopic, msg2)
      node3.ingessMessage(DefaultPubsubTopic, msg3)

      let f1 = node1.sync(node2PeerInfo)
      let f2 = node2.sync(node3PeerInfo)
      let f3 = node3.sync(node1PeerInfo)

      waitFor allFutures(f1, f2, f3)

      let hashes1 = f1.read()
      let hashes2 = f2.read()
      let hashes3 = f3.read()

      assert hashes1.isOk(), hashes1.error
      assert hashes2.isOk(), hashes2.error
      assert hashes3.isOk(), hashes3.error

      check:
        hashes1.get()[0].len == 1
        hashes2.get()[0].len == 1
        hashes3.get()[0].len == 1

        hashes1.get()[0][0] == hash2
        hashes2.get()[0][0] == hash3
        hashes3.get()[0][0] == hash1

      await allFutures(node1.stop(), node2.stop(), node3.stop())
      await allFutures(node1Switch.stop(), node2Switch.stop(), node3Switch.stop())
