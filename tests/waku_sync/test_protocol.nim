{.used.}

import
  std/options,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/crypto/crypto,
  stew/byteutils


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
            #s2 = new_storage()
            ng1 = new_negentropy(s1,10000)

        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msgHash: WakuMessageHash = computeMessageHash(pubsubTopic=DefaultPubsubTopic, msg1)
        var ret = insert(s1, msg1.timestamp, msgHash)
        if ret:
            debug "inserted msg successfully to storage", hash=msgHash.to0xHex()
        let output = initiate(ng1)
        debug "initialized negentropy and output is ", output=output
        ret = erase(s1, msg1.timestamp, msgHash)
        if ret:
            debug "removed msg successfully from storage", hash=msgHash.to0xHex()

    asyncTest "sync between 2 nodes":
        ## Setup
        let
            serverSwitch = newTestSwitch()
            clientSwitch = newTestSwitch()
        
        await allFutures(serverSwitch.start(), clientSwitch.start())
    
        let serverPeerInfo = serverSwitch.peerInfo.toRemotePeerInfo()
        let msg1 = fakeWakuMessage(contentTopic=DefaultContentTopic)
        let msg2 = fakeWakuMessage(contentTopic=DefaultContentTopic)

        let protoHandler:WakuSyncCallback = proc(hashes: seq[WakuMessageHash]) {.async: (raises: []), closure, gcsafe.} = 
            debug "Received needHashes from client:", len = hashes.len
            for hash in hashes:
                debug "Hash received from Client:", hash=hash.to0xHex()

        let
            server = await newTestWakuSync(serverSwitch, handler=protoHandler)
            client = await newTestWakuSync(clientSwitch, handler=protoHandler)
        server.ingessMessage(DefaultPubsubTopic, msg1)
        client.ingessMessage(DefaultPubsubTopic, msg1)
        server.ingessMessage(DefaultPubsubTopic, msg2)

        let hashes = await client.sync(serverPeerInfo)
        require (hashes.isOk())
        debug "Received needHashes from server:", len = hashes.value.len