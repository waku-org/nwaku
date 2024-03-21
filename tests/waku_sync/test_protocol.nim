{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  stew/byteutils,
  std/random,
  std/times

from std/os import sleep

import
  ../../../waku/[
    common/paging,
    node/peer_manager,
    waku_core,
    waku_core/message/digest,
    waku_sync,
    waku_sync/raw_bindings,
  ],
  ../testlib/[common, wakucore],
  ./sync_utils

random.randomize()

suite "Waku Sync - Protocol Tests":
  asyncTest "test c integration":
    let s1Res = Storage.new()
    let s1 = s1Res.value
    assert s1Res.isOk(), $s1Res.error
    let s2Res = Storage.new()
    let s2 = s2Res.value
    assert s2Res.isOk(), $s2Res.error

    let ng1Res = Negentropy.new(s1, 10000)
    assert ng1Res.isOk(), $ng1Res.error
    let ng1 = ng1Res.value
    let ng2Res = Negentropy.new(s2, 10000)
    assert ng2Res.isOk(), $ng2Res.error
    let ng2 = ng2Res.value

    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msgHash: WakuMessageHash =
      computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1)

    check:
      s1.insert(msg1.timestamp, msgHash).isOk()
      s2.insert(msg1.timestamp, msgHash).isOk()

    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msgHash2: WakuMessageHash =
      computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)

    check:
      s2.insert(msg2.timestamp, msgHash2).isOk()

    let ng1_q1 = ng1.initiate()
    check:
      ng1_q1.isOk()

    let ng2_q1 = ng2.serverReconcile(ng1_q1.get())
    check:
      ng2_q1.isOk()

    var
      haveHashes: seq[WakuMessageHash]
      needHashes: seq[WakuMessageHash]
    let ng1_q2 = ng1.clientReconcile(ng2_q1.get(), haveHashes, needHashes)

    check:
      needHashes.len() == 1
      haveHashes.len() == 0
      ng1_q2.isOk()
      needHashes[0] == msgHash2

    check:
      s1.erase(msg1.timestamp, msgHash).isOk()

  asyncTest "sync 2 nodes both empty":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)

    var hashes = await client.sync(serverPeerInfo)
    require (hashes.isOk())
    check:
      hashes.value.len == 0

  asyncTest "sync 2 nodes empty client full server":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)

    server.ingessMessage(DefaultPubsubTopic, msg1)
    server.ingessMessage(DefaultPubsubTopic, msg2)
    server.ingessMessage(DefaultPubsubTopic, msg3)

    var hashes = await client.sync(serverPeerInfo)
    require (hashes.isOk())
    check:
      hashes.value.len == 3
      computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg1) in hashes.value
      computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2) in hashes.value
      computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg3) in hashes.value

  asyncTest "sync 2 nodes full client empty server":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)

    client.ingessMessage(DefaultPubsubTopic, msg1)
    client.ingessMessage(DefaultPubsubTopic, msg2)
    client.ingessMessage(DefaultPubsubTopic, msg3)

    var hashes = await client.sync(serverPeerInfo)
    require (hashes.isOk())
    check:
      hashes.value.len == 0

  asyncTest "sync 2 nodes different hashes":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)
    server.ingessMessage(DefaultPubsubTopic, msg1)
    client.ingessMessage(DefaultPubsubTopic, msg1)
    server.ingessMessage(DefaultPubsubTopic, msg2)

    var hashes = await client.sync(serverPeerInfo)
    require (hashes.isOk())
    check:
      hashes.value.len == 1
      hashes.value[0] == computeMessageHash(pubsubTopic = DefaultPubsubTopic, msg2)
    #Assuming message is fetched from peer
    client.ingessMessage(DefaultPubsubTopic, msg2)
    sleep(1000)
    hashes = await client.sync(serverPeerInfo)
    require (hashes.isOk())
    check:
      hashes.value.len == 0

  asyncTest "sync 2 nodes same hashes":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)
    server.ingessMessage(DefaultPubsubTopic, msg1)
    client.ingessMessage(DefaultPubsubTopic, msg1)
    server.ingessMessage(DefaultPubsubTopic, msg2)
    client.ingessMessage(DefaultPubsubTopic, msg2)

    let hashes = await client.sync(serverPeerInfo)
    assert hashes.isOk(), $hashes.error
    check:
      hashes.value.len == 0

  asyncTest "sync 2 nodes 100K msgs":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)
    var i = 0
    let msgCount = 100000
    var diffIndex = rand(msgCount)
    debug "diffIndex is ", diffIndex = diffIndex
    var diffMsg: WakuMessage
    while i < msgCount:
      let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
      if i != diffIndex:
        client.ingessMessage(DefaultPubsubTopic, msg)
      else:
        diffMsg = msg
      server.ingessMessage(DefaultPubsubTopic, msg)
      i = i + 1

    let hashes = await client.sync(serverPeerInfo)
    assert hashes.isOk(), $hashes.error
    check:
      hashes.value.len == 1
      hashes.value[0] == computeMessageHash(DefaultPubsubTopic, diffMsg)

  asyncTest "sync 2 nodes 100K msgs 10K diffs":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client = await newTestWakuSync(clientSwitch, handler = protoHandler)
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
      i = i + 1

    i = 0
    var tmpDiffCnt = diffCount
    while i < msgCount:
      let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
      if tmpDiffCnt > 0 and i in randIndexes:
        #info "not ingessing in client", i=i
        diffMsgHashes.add(computeMessageHash(DefaultPubsubTopic, msg))
        tmpDiffCnt = tmpDiffCnt - 1
      else:
        client.ingessMessage(DefaultPubsubTopic, msg)

      server.ingessMessage(DefaultPubsubTopic, msg)
      i = i + 1
    let hashes = await client.sync(serverPeerInfo)
    assert hashes.isOk(), $hashes.error
    check:
      hashes.value.len == diffCount
      #TODO: Check if all diffHashes are there in needHashes        

  asyncTest "sync 3 nodes 2 client 1 server":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      client1Switch = newTestSwitch()
      client2Switch = newTestSwitch()

    await allFutures(serverSwitch.start(), client1Switch.start(), client2Switch.start())

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      trace "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        trace "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client1 = await newTestWakuSync(client1Switch, handler = protoHandler)
      client2 = await newTestWakuSync(client2Switch, handler = protoHandler)
    let msgCount = 10000
    var i = 0

    while i < msgCount:
      i = i + 1
      let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
      if i mod 2 == 0:
        client2.ingessMessage(DefaultPubsubTopic, msg)
      else:
        client1.ingessMessage(DefaultPubsubTopic, msg)
      server.ingessMessage(DefaultPubsubTopic, msg)

    let fut1 = client1.sync(serverPeerInfo)
    let fut2 = client2.sync(serverPeerInfo)
    waitFor allFutures(fut1, fut2)

    let hashes1 = fut1.read()
    let hashes2 = fut2.read()

    assert hashes1.isOk(), $hashes1.error
    assert hashes2.isOk(), $hashes2.error

    check:
      hashes1.value.len == int(msgCount / 2)
      hashes2.value.len == int(msgCount / 2)

      #TODO: Check if all diffHashes are there in needHashes

  asyncTest "sync 6 nodes varying sync diffs":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      client1Switch = newTestSwitch()
      client2Switch = newTestSwitch()
      client3Switch = newTestSwitch()
      client4Switch = newTestSwitch()
      client5Switch = newTestSwitch()

    await allFutures(
      serverSwitch.start(),
      client1Switch.start(),
      client2Switch.start(),
      client3Switch.start(),
      client4Switch.start(),
      client5Switch.start(),
    )

    let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      server = await newTestWakuSync(serverSwitch, handler = protoHandler)
      client1 = await newTestWakuSync(client1Switch, handler = protoHandler)
      client2 = await newTestWakuSync(client2Switch, handler = protoHandler)
      client3 = await newTestWakuSync(client3Switch, handler = protoHandler)
      client4 = await newTestWakuSync(client4Switch, handler = protoHandler)
      client5 = await newTestWakuSync(client5Switch, handler = protoHandler)

    let msgCount = 100000
    var i = 0

    while i < msgCount:
      let msg = fakeWakuMessage(contentTopic = DefaultContentTopic)
      if i < msgCount - 1:
        client1.ingessMessage(DefaultPubsubTopic, msg)
      if i < msgCount - 10:
        client2.ingessMessage(DefaultPubsubTopic, msg)
      if i < msgCount - 100:
        client3.ingessMessage(DefaultPubsubTopic, msg)
      if i < msgCount - 1000:
        client4.ingessMessage(DefaultPubsubTopic, msg)
      if i < msgCount - 10000:
        client5.ingessMessage(DefaultPubsubTopic, msg)
      server.ingessMessage(DefaultPubsubTopic, msg)
      i = i + 1
    info "client2 storage size", size = client2.storageSize()

    var timeBefore = cpuTime()
    let hashes1 = await client1.sync(serverPeerInfo)
    var timeAfter = cpuTime()
    var syncTime = (timeAfter - timeBefore)
    info "sync time in seconds", msgsTotal = msgCount, diff = 1, syncTime = syncTime
    assert hashes1.isOk(), $hashes1.error
    check:
      hashes1.value.len == 1
      #TODO: Check if all diffHashes are there in needHashes

    timeBefore = cpuTime()
    let hashes2 = await client2.sync(serverPeerInfo)
    timeAfter = cpuTime()
    syncTime = (timeAfter - timeBefore)
    info "sync time in seconds", msgsTotal = msgCount, diff = 10, syncTime = syncTime
    assert hashes2.isOk(), $hashes2.error
    check:
      hashes2.value.len == 10
      #TODO: Check if all diffHashes are there in needHashes

    timeBefore = cpuTime()
    let hashes3 = await client3.sync(serverPeerInfo)
    timeAfter = cpuTime()
    syncTime = (timeAfter - timeBefore)
    info "sync time in seconds", msgsTotal = msgCount, diff = 100, syncTime = syncTime
    assert hashes3.isOk(), $hashes3.error
    check:
      hashes3.value.len == 100
      #TODO: Check if all diffHashes are there in needHashes

    timeBefore = cpuTime()
    let hashes4 = await client4.sync(serverPeerInfo)
    timeAfter = cpuTime()
    syncTime = (timeAfter - timeBefore)
    info "sync time in seconds", msgsTotal = msgCount, diff = 1000, syncTime = syncTime
    assert hashes4.isOk(), $hashes4.error
    check:
      hashes4.value.len == 1000
      #TODO: Check if all diffHashes are there in needHashes

    timeBefore = cpuTime()
    let hashes5 = await client5.sync(serverPeerInfo)
    timeAfter = cpuTime()
    syncTime = (timeAfter - timeBefore)
    info "sync time in seconds", msgsTotal = msgCount, diff = 10000, syncTime = syncTime
    assert hashes5.isOk(), $hashes5.error
    check:
      hashes5.value.len == 10000
      #TODO: Check if all diffHashes are there in needHashes

  asyncTest "sync 3 nodes cyclic":
    let
      node1Switch = newTestSwitch()
      node2Switch = newTestSwitch()
      node3Switch = newTestSwitch()

    await allFutures(node1Switch.start(), node2Switch.start(), node3Switch.start())

    let node1PeerInfo = node1Switch.peerInfo.toRemotePeerInfo()
    let node2PeerInfo = node2Switch.peerInfo.toRemotePeerInfo()
    let node3PeerInfo = node3Switch.peerInfo.toRemotePeerInfo()

    let msg1 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash1 = computeMessageHash(DefaultPubsubTopic, msg1)
    let msg2 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash2 = computeMessageHash(DefaultPubsubTopic, msg2)
    let msg3 = fakeWakuMessage(contentTopic = DefaultContentTopic)
    let hash3 = computeMessageHash(DefaultPubsubTopic, msg3)

    let protoHandler: WakuSyncCallback = proc(
        hashes: seq[WakuMessageHash], peer: RemotePeerInfo
    ) {.async: (raises: []), closure, gcsafe.} =
      debug "Received needHashes from peer:", len = hashes.len
      for hash in hashes:
        debug "Hash received from peer:", hash = hash.to0xHex()

    let
      node1 = await newTestWakuSync(node1Switch, handler = protoHandler)
      node2 = await newTestWakuSync(node2Switch, handler = protoHandler)
      node3 = await newTestWakuSync(node3Switch, handler = protoHandler)

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
      hashes1.get().len == 1
      hashes2.get().len == 1
      hashes3.get().len == 1

      hashes1.get()[0] == hash2
      hashes2.get()[0] == hash3
      hashes3.get()[0] == hash1
