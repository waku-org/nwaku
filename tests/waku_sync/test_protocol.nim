{.used.}

import
  std/options,
  #std/asyncdispatch,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  stew/byteutils
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


suite "Waku Sync - Protocol Tests":

    asyncTest "test c integration":
        let 
            s1 = negentropyNewStorage()
            s2 = negentropyNewStorage()
            ng1 = negentropyNew(s1,10000)
            ng2 = negentropyNew(s2,10000)

        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg1)
        var ret = negentropyStorageInsert(s1, msg1.timestamp, msgHash)
        check:
          ret == true

        ret = negentropyStorageInsert(s2, msg1.timestamp, msgHash)
        check:
          ret == true

        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash2: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg2)
        ret = negentropyStorageInsert(s2, msg2.timestamp, msgHash2)
        check:
          ret == true

        let ng1_q1 = negentropyInitiate(ng1)
        check:
          ng1_q1.len > 0

        let ng2_q1 = negentropyServerReconcile(ng2, ng1_q1)
        check:
          ng2_q1.len > 0

        var
          haveHashes: seq[WakuMessageHash]
          needHashes: seq[WakuMessageHash]
        let ng1_q2 = negentropyClientReconcile(ng1, ng2_q1, haveHashes, needHashes)
        
        check:
          needHashes.len() == 1
          haveHashes.len() == 0
          ng1_q2.len == 0
          needHashes[0] == msgHash2

        ret = negentropyStorageErase(s1, msg1.timestamp, msgHash)
        check:
          ret == true

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

          proc synccallback(data: ptr) {.gcsafe, raises:[].}=
            let f1Result = f1.internalValue.valueOr("error 1")
            let f2Result = f2.internalValue.valueOr("error 2")
            let f3Result = f3.internalValue.valueOr("error 3")

            echo "inside callback result from f1: " & $f1Result
            echo "inside callback result from f2: " & $f2Result
            echo "inside callback result from f3: " & $f3Result

#[             let hashes = f1Res.read
            assert hashes.isOk(), $hashes.error
            check:
              hashes.value.len == 1 ]#


          let allFuts = allFutures(@[f1, f2, f3])
          allFuts.addCallback(synccallback)
          await allFuts

        waitFor waitAllFutures(f1, f2, f3)
 ]#