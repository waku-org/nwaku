{.used.}

import
  std/[unittest, sets],
  libp2p/crypto/crypto
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../test_helpers

suite "Peer Storage":

  test "Store, replace and retrieve from persistent peer storage":
    let 
      database = SqliteDatabase.new(":memory:").tryGet()
      storage = WakuPeerStorage.new(database)[]

      # Test Peer
      peerLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      peerKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      peer = PeerInfo.new(peerKey, @[peerLoc])
      peerProto = "/waku/2/default-waku/codec"
      stored = StoredInfo(peerId: peer.peerId, addrs: @[peerLoc], protos: @[peerProto], publicKey: peerKey.getPublicKey().tryGet())
      conn = Connectedness.CanConnect
      disconn = 999999
       
    defer: storage.close()
    
    # Test insert and retrieve

    discard storage.put(peer.peerId, stored, conn, disconn)
    
    var responseCount = 0
    # flags to check data matches what was stored (default true)
    var peerIdFlag, storedInfoFlag, connectednessFlag, disconnectFlag: bool

    proc data(peerId: PeerID, storedInfo: StoredInfo,
              connectedness: Connectedness, disconnectTime: int64) {.raises: [Defect].} =
      responseCount += 1
      
      # Note: cannot use `check` within `{.raises: [Defect].}` block
      # @TODO: /Nim/lib/pure/unittest.nim(577, 16) Error: can raise an unlisted exception: Exception
      # These flags are checked outside this block.
      peerIdFlag = peerId == peer.peerId
      storedInfoFlag = storedInfo == stored
      connectednessFlag = connectedness == conn
      disconnectFlag = disconnectTime == disconn
    
    let res = storage.getAll(data)
    
    check:
      res.isErr == false
      responseCount == 1
      peerIdFlag
      storedInfoFlag
      connectednessFlag
      disconnectFlag
    
    # Test replace and retrieve (update an existing entry)
    discard storage.put(peer.peerId, stored, Connectedness.CannotConnect, disconn + 10)
    
    responseCount = 0
    proc replacedData(peerId: PeerID, storedInfo: StoredInfo,
                      connectedness: Connectedness, disconnectTime: int64) {.raises: [Defect].} =
      responseCount += 1
      
      # Note: cannot use `check` within `{.raises: [Defect].}` block
      # @TODO: /Nim/lib/pure/unittest.nim(577, 16) Error: can raise an unlisted exception: Exception
      # These flags are checked outside this block.
      peerIdFlag = peerId == peer.peerId
      storedInfoFlag = storedInfo == stored
      connectednessFlag = connectedness == CannotConnect
      disconnectFlag = disconnectTime == disconn + 10

    let repRes = storage.getAll(replacedData)
    
    check:
      repRes.isErr == false
      responseCount == 1
      peerIdFlag
      storedInfoFlag
      connectednessFlag
      disconnectFlag
