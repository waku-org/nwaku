{.used.}

import
  std/[options, sets, tables, sequtils],
  chronicles,
  testutils/unittests, stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/[keys, rlp], eth/common/eth_types,
  libp2p/[builders, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message
import
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/storage/peer/waku_peer_storage,
  ../../waku/v2/node/waku_node,
  ../test_helpers

procSuite "Peer Manager":
  asyncTest "Peer dialing works":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.switch.peerInfo
    
    await allFutures([node1.start(), node2.start()])

    await node1.mountRelay()
    await node2.mountRelay()

    # Dial node2 from node1
    let conn = (await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec)).get()

    # Check connection
    check:
      conn.activity
      conn.peerId == peerInfo2.peerId
    
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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.switch.peerInfo
    
    await node1.start()
    # Purposefully don't start node2

    await node1.mountRelay()
    await node2.mountRelay()

    # Dial node2 from node1
    let connOpt = await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)

    # Check connection failed gracefully
    check:
      connOpt.isNone()
    
    await node1.stop()

  asyncTest "Adding, selecting and filtering peers work":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      # Create filter peer
      filterLoc = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      filterKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      filterPeer = PeerInfo.new(filterKey, @[filterLoc])
      # Create swap peer
      swapLoc = MultiAddress.init("/ip4/127.0.0.2/tcp/2").tryGet()
      swapKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      swapPeer = PeerInfo.new(swapKey, @[swapLoc])
      # Create store peer
      storeLoc = MultiAddress.init("/ip4/127.0.0.3/tcp/4").tryGet()
      storeKey = crypto.PrivateKey.random(ECDSA, rng[]).get()
      storePeer = PeerInfo.new(storeKey, @[storeLoc])
    
    await node.start()

    await node.mountFilter()
    await node.mountSwap()
    node.mountStoreClient()

    node.wakuFilter.setPeer(filterPeer.toRemotePeerInfo())
    node.wakuSwap.setPeer(swapPeer.toRemotePeerInfo())
    
    node.setStorePeer(storePeer.toRemotePeerInfo())

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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.switch.peerInfo
    
    await node1.start()

    await node1.mountRelay()
    await node2.mountRelay()

    # Test default connectedness for new peers
    node1.peerManager.addPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec)
    check:
      # No information about node2's connectedness
      node1.peerManager.connectedness(peerInfo2.peerId) == NotConnected

    # Purposefully don't start node2
    # Attempt dialing node2 from node1
    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Cannot connect to node2
      node1.peerManager.connectedness(peerInfo2.peerId) == CannotConnect

    # Successful connection
    await node2.start()
    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
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
      database = SqliteDatabase.init("1", inMemory = true)[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.switch.peerInfo
    
    await node1.start()
    await node2.start()

    await node1.mountRelay()
    await node2.mountRelay()

    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.peers().len == 1
      node1.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60004), peerStorage = storage)
    
    await node3.start()
    check:
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.connectedness(peerInfo2.peerId) == NotConnected

    await node3.mountRelay()  # This should trigger a reconnect
    
    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.connectedness(peerInfo2.peerId) == Connected
    
    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Peer manager support multiple protocol IDs when reconnecting to peers":
    let
      database = SqliteDatabase.init("2", inMemory = true)[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.switch.peerInfo
      betaCodec = "/vac/waku/relay/2.0.0-beta2"
      stableCodec = "/vac/waku/relay/2.0.0"
    
    await node1.start()
    await node2.start()

    await node1.mountRelay()
    node1.wakuRelay.codec = betaCodec
    await node2.mountRelay()
    node2.wakuRelay.codec = betaCodec

    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), node2.wakuRelay.codec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.peers().len == 1
      node1.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.peers().anyIt(it.protos.contains(node2.wakuRelay.codec))
      node1.peerManager.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60004), peerStorage = storage)
    
    await node3.mountRelay()
    node3.wakuRelay.codec = stableCodec
    check:
      # Node 2 and 3 have differing codecs
      node2.wakuRelay.codec == betaCodec
      node3.wakuRelay.codec == stableCodec
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peers().anyIt(it.protos.contains(betaCodec))
      node3.peerManager.connectedness(peerInfo2.peerId) == NotConnected
    
    await node3.start() # This should trigger a reconnect

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.peers().len == 1
      node3.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peers().anyIt(it.protos.contains(betaCodec))
      node3.peerManager.peers().anyIt(it.protos.contains(stableCodec))
      node3.peerManager.connectedness(peerInfo2.peerId) == Connected
    
    await allFutures([node1.stop(), node2.stop(), node3.stop()])
