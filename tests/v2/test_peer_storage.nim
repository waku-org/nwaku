{.used.}

import
  std/[unittest, sets],
  libp2p/crypto/crypto,
  ../test_helpers,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/node/storage/peer/waku_peer_storage

suite "Peer Storage":

  test "Store and retrieve from persistent peer storage":
    let 
      database = SqliteDatabase.init("", inMemory = true)[]
      storage = WakuPeerStorage.init(database)[]

      # Test Peer
      peerLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      peerKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.init(peerKey, @[peerLoc])
      peerProto = "/waku/2/default-waku/codec"
      stored = StoredInfo(peerId: peer.peerId, addrs: toHashSet([peerLoc]), protos: toHashSet([peerProto]), publicKey: peerKey.getKey().tryGet())
      conn = Connectedness.CanConnect
       
    defer: storage.close()
    
    discard storage.put(peer.peerId, stored, conn)
    
    var responseCount = 0
    proc data(peerId: PeerID, storedInfo: StoredInfo,
              connectedness: Connectedness) =
      responseCount += 1
      check:
        peerId == peer.peerId
        storedInfo == stored
        connectedness == conn
    
    let res = storage.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 1
