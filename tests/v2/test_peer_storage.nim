{.used.}

import
  testutils/unittests,
  libp2p/crypto/crypto
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ./testlib/waku2


suite "Peer Storage":

  test "Store, replace and retrieve from persistent peer storage":
    let
      database = SqliteDatabase.new(":memory:").tryGet()
      storage = WakuPeerStorage.new(database)[]

      # Test Peer
      peerLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      peerKey = generateEcdsaKey()
      peer = PeerInfo.new(peerKey, @[peerLoc])
      peerProto = "/waku/2/default-waku/codec"
      connectedness = Connectedness.CanConnect
      disconn = 999999
      stored = RemotePeerInfo(
        peerId: peer.peerId,
        addrs: @[peerLoc],
        protocols: @[peerProto],
        publicKey: peerKey.getPublicKey().tryGet(),
        connectedness: connectedness,
        disconnectTime: disconn)

    defer: storage.close()

    # Test insert and retrieve

    require storage.put(peer.peerId, stored, connectedness, disconn).isOk

    var responseCount = 0

    # Fetched variables from callback
    var resPeerId: PeerId
    var resStoredInfo: RemotePeerInfo
    var resConnectedness: Connectedness
    var resDisconnect: int64

    proc data(peerId: PeerID, storedInfo: RemotePeerInfo,
              connectedness: Connectedness, disconnectTime: int64) {.raises: [Defect].} =
      responseCount += 1

      # Note: cannot use `check` within `{.raises: [Defect].}` block
      # @TODO: /Nim/lib/pure/unittest.nim(577, 16) Error: can raise an unlisted exception: Exception
      # These flags are checked outside this block.
      resPeerId = peerId
      resStoredInfo = storedInfo
      resConnectedness = connectedness
      resDisconnect = disconnectTime

    let res = storage.getAll(data)

    check:
      res.isErr == false
      responseCount == 1
      resPeerId == peer.peerId
      resStoredInfo.peerId == peer.peerId
      resStoredInfo.addrs == @[peerLoc]
      resStoredInfo.protocols == @[peerProto]
      resStoredInfo.publicKey == peerKey.getPublicKey().tryGet()
      # TODO: For compatibility, we don't store connectedness and disconnectTime
      #resStoredInfo.connectedness == connectedness
      #resStoredInfo.disconnectTime == disconn
      resConnectedness == Connectedness.CanConnect
      resDisconnect == disconn

    # Test replace and retrieve (update an existing entry)
    require storage.put(peer.peerId, stored, Connectedness.CannotConnect, disconn + 10).isOk

    responseCount = 0
    proc replacedData(peerId: PeerID, storedInfo: RemotePeerInfo,
                      connectedness: Connectedness, disconnectTime: int64) {.raises: [Defect].} =
      responseCount += 1

      # Note: cannot use `check` within `{.raises: [Defect].}` block
      # @TODO: /Nim/lib/pure/unittest.nim(577, 16) Error: can raise an unlisted exception: Exception
      # These flags are checked outside this block.
      resPeerId = peerId
      resStoredInfo = storedInfo
      resConnectedness = connectedness
      resDisconnect = disconnectTime

    let repRes = storage.getAll(replacedData)

    check:
      repRes.isErr == false
      responseCount == 1
      resPeerId == peer.peerId
      resStoredInfo.peerId == peer.peerId
      resStoredInfo.addrs == @[peerLoc]
      resStoredInfo.protocols == @[peerProto]
      resStoredInfo.publicKey == peerKey.getPublicKey().tryGet()
      # TODO: For compatibility, we don't store connectedness and disconnectTime
      #resStoredInfo.connectedness == connectedness
      #resStoredInfo.disconnectTime == disconn
      resConnectedness == Connectedness.CannotConnect
      resDisconnect == disconn + 10
