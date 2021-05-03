{.used.}

import
  std/[options, sets, tables, sequtils],
  testutils/unittests, stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/[keys, rlp], eth/common/eth_types,
  libp2p/[standard_setup, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/storage/peer/waku_peer_storage,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_filter/waku_filter,
  ../../waku/v2/protocol/waku_store/waku_store,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../test_helpers

procSuite "Peer Manager":
  asyncTest "Peer dialing works":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
    
    await allFutures([node1.start(), node2.start()])

    node1.mountRelay()
    node2.mountRelay()

    # Dial node2 from node1
    let conn = (await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec)).get()

    # Check connection
    check:
      conn.activity
      conn.peerInfo.peerId == peerInfo2.peerId
    
    # Check that node2 is being managed in node1
    check:
      node1.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)

    # Check connectedness
    check:
      node1.peerManager.connectedness(peerInfo2.peerId) == Connectedness.Connected
    
    await allFutures([node1.stop(), node2.stop()])
  
  asyncTest "Dialing fails gracefully":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
    
    await node1.start()
    # Purposefully don't start node2

    node1.mountRelay()
    node2.mountRelay()

    # Dial node2 from node1
    let connOpt = await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec, 2.seconds)

    # Check connection failed gracefully
    check:
      connOpt.isNone()
    
    await node1.stop()

  asyncTest "Adding, selecting and filtering peers work":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.init(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      # Create filter peer
      filterLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      filterKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      filterPeer = PeerInfo.init(filterKey, @[filterLoc])
      # Create swap peer
      swapLoc = MultiAddress.init("/ip4/127.0.0.2/tcp/2").tryGet()
      swapKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      swapPeer = PeerInfo.init(swapKey, @[swapLoc])
      # Create store peer
      storeLoc = MultiAddress.init("/ip4/127.0.0.3/tcp/4").tryGet()
      storeKey = wakunode2.PrivateKey.random(ECDSA, rng[]).get()
      storePeer = PeerInfo.init(storeKey, @[storeLoc])
    
    await node.start()

    node.mountFilter()
    node.mountSwap()
    node.mountStore(persistMessages = true)

    node.wakuFilter.setPeer(filterPeer)
    node.wakuSwap.setPeer(swapPeer)
    node.wakuStore.setPeer(storePeer)

    # Check peers were successfully added to peer manager
    check:
      node.peerManager.peers().len == 3
      node.peerManager.peers(WakuFilterCodec).allIt(it.peerId == filterPeer.peerId and
                                                    it.addrs.contains(filterLoc) and
                                                    it.protos.contains(WakuFilterCodec))
      node.peerManager.peers(WakuSwapCodec).allIt(it.peerId == swapPeer.peerId and
                                                  it.addrs.contains(swapLoc) and
                                                  it.protos.contains(WakuSwapCodec))
      node.peerManager.peers(WakuStoreCodec).allIt(it.peerId == storePeer.peerId and
                                                   it.addrs.contains(storeLoc) and
                                                   it.protos.contains(WakuStoreCodec))
    
    await node.stop()
  

  asyncTest "Peer manager keeps track of connections":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
    
    await node1.start()

    node1.mountRelay()
    node2.mountRelay()

    # Test default connectedness for new peers
    node1.peerManager.addPeer(peerInfo2, WakuRelayCodec)
    check:
      # No information about node2's connectedness
      node1.peerManager.connectedness(peerInfo2.peerId) == NotConnected

    # Purposefully don't start node2
    # Attempt dialing node2 from node1
    discard await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec, 2.seconds)
    check:
      # Cannot connect to node2
      node1.peerManager.connectedness(peerInfo2.peerId) == CannotConnect

    # Successful connection
    await node2.start()
    discard await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.connectedness(peerInfo2.peerId) == Connected

    # Stop node. Gracefully disconnect from all peers.
    await node1.stop()
    check:
      # Not currently connected to node2, but had recent, successful connection.
      node1.peerManager.connectedness(peerInfo2.peerId) == CanConnect
    
    await node2.stop()

  asyncTest "Peer manager can use persistent storage and survive restarts":
    let
      database = SqliteDatabase.init("", inMemory = true)[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
    
    await node1.start()
    await node2.start()

    node1.mountRelay()
    node2.mountRelay()

    discard await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.peers().len == 1
      node1.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.init(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60004), peerStorage = storage)
    
    await node3.start()
    check:
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.connectedness(peerInfo2.peerId) == NotConnected

    node3.mountRelay()  # This should trigger a reconnect
    
    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.connectedness(peerInfo2.peerId) == Connected
    
    await allFutures([node1.stop(), node2.stop(), node3.stop()])
