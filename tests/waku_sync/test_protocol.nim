{.used.}

import
  std/options,
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
            s1 = new_storage()
            s2 = new_storage()
            ng1 = new_negentropy(s1,10000)
            ng2 = new_negentropy(s2,10000)

        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg1)
        var ret = insert(s1, msg1.timestamp, msgHash)
        check:
          ret == true

        ret = insert(s2, msg1.timestamp, msgHash)
        check:
          ret == true

        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash2: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg2)
        ret = insert(s2, msg2.timestamp, msgHash2)
        check:
          ret == true

        let ng1_q1 = initiate(ng1)
        check:
          ng1_q1.len > 0

        let ng2_q1 = serverReconcile(ng2, ng1_q1)
        check:
          ng2_q1.len > 0

        var
          haveHashes: seq[WakuMessageHash]
          needHashes: seq[WakuMessageHash]
        let ng1_q2 = clientReconcile(ng1, ng2_q1, haveHashes, needHashes)
        
        check:
          needHashes.len() == 1
          haveHashes.len() == 0
          ng1_q2.len == 0
          needHashes[0] == msgHash2

        ret = erase(s1, msg1.timestamp, msgHash)
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
#[         client.ingessMessage(DefaultPubsubTopic, msg2)
        sleep(1000)
        hashes = await client.sync(serverPeerInfo)
        require (hashes.isOk())
        check:
          hashes.value.len == 0 ]#

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
