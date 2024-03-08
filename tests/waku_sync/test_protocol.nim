{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  stew/byteutils,
  std/random
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
  ../testlib/[
    common,
    wakucore
  ],
  ./sync_utils

random.randomize()

suite "Waku Sync - Protocol Tests":

    asyncTest "test c integration":
        let 
            s1 = Storage.new()
            s2 = Storage.new()
            ng1 = Negentropy.new(s1,10000)
            ng2 = Negentropy.new(s2,10000)

        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg1)
 
        check:
          s1.insert(msg1.timestamp, msgHash).isOk()
          s2.insert(msg1.timestamp, msgHash).isOk()

        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash2: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg2)

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

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)

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
        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg3 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)

        server.ingessMessage(DefaultPubsubTopic, msg1)
        server.ingessMessage(DefaultPubsubTopic, msg2)
        server.ingessMessage(DefaultPubsubTopic, msg3)

        var hashes = await client.sync(serverPeerInfo)
        require (hashes.isOk())
        check:
          hashes.value.len == 3
          computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg1) in hashes.value
          computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg2) in hashes.value
          computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg3) in hashes.value

    asyncTest "sync 2 nodes full client empty server":
        ## Setup
        let
            serverSwitch = newTestSwitch()
            clientSwitch = newTestSwitch()
        
        await allFutures(serverSwitch.start(), clientSwitch.start())
    
        let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg3 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)

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
        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)
        server.ingessMessage(DefaultPubsubTopic, msg1)
        client.ingessMessage(DefaultPubsubTopic, msg1)
        server.ingessMessage(DefaultPubsubTopic, msg2)

        var hashes = await client.sync(serverPeerInfo)
        require (hashes.isOk())
        check:
          hashes.value.len == 1
          hashes.value[0] == computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg2)
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
        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)
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

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)
        var i = 0
        let msgCount = 1000
        var diffIndex = rand(msgCount)
        debug "diffIndex is ",diffIndex=diffIndex
        var diffMsg: WakuMessage
        while i < msgCount:
          let msg = fakeWakuMessage(contentTopic=DefaultContentTopic)
          if i != diffIndex:
            client.ingessMessage(DefaultPubsubTopic,msg)
          else:
            diffMsg = msg
          server.ingessMessage(DefaultPubsubTopic,msg)
          i = i + 1

        let hashes = await client.sync(serverPeerInfo)
        assert hashes.isOk(), $hashes.error
        check:
          hashes.value.len == 1
          hashes.value[0] == computeMessageHash(DefaultPubsubTopic,diffMsg)
          

#[     asyncTest "sync 3 nodes cyclic":
        #[Setup
        node1 (client) <--> node2(server)
        node2(client) <--> node3(server)
        node3(client) <--> node1(server)]#

        let
            node1Switch = newTestSwitch()
            node2Switch = newTestSwitch()
            node3Switch = newTestSwitch()
        
        await allFutures(node1Switch.start(), node2Switch.start(), node3Switch.start())
    
        let node1PeerInfo = node1Switch.peerInfo.toRemotePeerInfo()
        let node2PeerInfo = node2Switch.peerInfo.toRemotePeerInfo()
        let node3PeerInfo = node3Switch.peerInfo.toRemotePeerInfo()

        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg3 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from peer:", len = hashes.len
            for hash in hashes:
                debug "Hash received from peer:", hash=hash.to0xHex()

        let
            node1 = await newTestWakuSync(node1Switch, handler=protoHandler)
            node2 = await newTestWakuSync(node2Switch, handler=protoHandler)
            node3 = await newTestWakuSync(node3Switch, handler=protoHandler)

        node1.ingessMessage(DefaultPubsubTopic, msg1)
        node2.ingessMessage(DefaultPubsubTopic, msg1)
        node2.ingessMessage(DefaultPubsubTopic, msg2)
        node3.ingessMessage(DefaultPubsubTopic, msg3)

        let f1 = node1.sync(node2PeerInfo)
        let f2 = node2.sync(node3PeerInfo)
        let f3 = node3.sync(node1PeerInfo)

        ## gather all futures in one
        proc waitAllFutures(f1, f2, f3: Future[Result[seq[WakuMessageHash], string]]) {.async.} =

          proc synccallback(data: pointer) =
            let f1Result = f1.internalValue
            assert f1Result.isOk(), f1Result.error

            let f2Result = f2.internalValue
            assert f2Result.isOk(), f2Result.error

            let f3Result = f3.internalValue
            assert f3Result.isOk(), f3Result.error

            let hashes1 = f1Result.get()
            let hashes2 = f2Result.get()
            let hashes3 = f3Result.get()

            check:
              hashes1.len == 1
              hashes2.len == 1
              hashes3.len == 1

          let allFuts = allFutures(@[f1, f2, f3])
          allFuts.addCallback(synccallback)
          await allFuts

        waitFor waitAllFutures(f1, f2, f3) ]#
