{.used.}

import
  std/[options, sequtils],
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  json_rpc/rpcserver,
  json_rpc/rpcclient,
  eth/keys,
  eth/common/eth_types,
  libp2p/[builders, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message
import
  ../../waku/common/sqlite,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/peer_manager/peer_store/waku_peer_storage,
  ../../waku/v2/node/waku_node,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/protocol/waku_store,
  ../../waku/v2/protocol/waku_filter,
  ../../waku/v2/protocol/waku_swap/waku_swap,
  ../test_helpers,
  ./testlib/testutils

procSuite "Peer Manager":
  asyncTest "Peer dialing works":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60800))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60802))
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
      node1.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)

    # Check connectedness
    check:
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connectedness.Connected

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Dialing fails gracefully":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60810))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60812))
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
      node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60820))
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

    await node.mountFilterClient()
    await node.mountSwap()
    node.mountStoreClient()

    node.wakuSwap.setPeer(swapPeer.toRemotePeerInfo())

    node.setStorePeer(storePeer.toRemotePeerInfo())
    node.setFilterPeer(filterPeer.toRemotePeerInfo())

    # Check peers were successfully added to peer manager
    check:
      node.peerManager.peerStore.peers().len == 3
      node.peerManager.peerStore.peers(WakuFilterCodec).allIt(it.peerId == filterPeer.peerId and
                                                              it.addrs.contains(filterLoc) and
                                                              it.protos.contains(WakuFilterCodec))
      node.peerManager.peerStore.peers(WakuSwapCodec).allIt(it.peerId == swapPeer.peerId and
                                                            it.addrs.contains(swapLoc) and
                                                            it.protos.contains(WakuSwapCodec))
      node.peerManager.peerStore.peers(WakuStoreCodec).allIt(it.peerId == storePeer.peerId and
                                                             it.addrs.contains(storeLoc) and
                                                             it.protos.contains(WakuStoreCodec))

    await node.stop()


  asyncTest "Peer manager keeps track of connections":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60830))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60832))
      peerInfo2 = node2.switch.peerInfo

    await node1.start()

    await node1.mountRelay()
    await node2.mountRelay()

    # Test default connectedness for new peers
    node1.peerManager.addPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec)
    check:
      # No information about node2's connectedness
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    # Purposefully don't start node2
    # Attempt dialing node2 from node1
    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Cannot connect to node2
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == CannotConnect

    # Successful connection
    await node2.start()
    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Stop node. Gracefully disconnect from all peers.
    await node1.stop()
    check:
      # Not currently connected to node2, but had recent, successful connection.
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == CanConnect

    await node2.stop()

  asyncTest "Peer manager can use persistent storage and survive restarts":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60840), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60842))
      peerInfo2 = node2.switch.peerInfo

    await node1.start()
    await node2.start()

    await node1.mountRelay()
    await node2.mountRelay()

    discard await node1.peerManager.dialPeer(peerInfo2.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      node1.peerManager.peerStore.peers().len == 1
      node1.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60844), peerStorage = storage)

    await node3.start()
    check:
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.peerStore.peers().len == 1
      node3.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    await node3.mountRelay()  # This should trigger a reconnect

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.peerStore.peers().len == 1
      node3.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  # TODO: nwaku/issues/1377
  xasyncTest "Peer manager support multiple protocol IDs when reconnecting to peers":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60850), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60852))
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
      node1.peerManager.peerStore.peers().len == 1
      node1.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node1.peerManager.peerStore.peers().anyIt(it.protos.contains(node2.wakuRelay.codec))
      node1.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connected

    # Simulate restart by initialising a new node using the same storage
    let
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(60854), peerStorage = storage)

    await node3.mountRelay()
    node3.wakuRelay.codec = stableCodec
    check:
      # Node 2 and 3 have differing codecs
      node2.wakuRelay.codec == betaCodec
      node3.wakuRelay.codec == stableCodec
      # Node2 has been loaded after "restart", but we have not yet reconnected
      node3.peerManager.peerStore.peers().len == 1
      node3.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peerStore.peers().anyIt(it.protos.contains(betaCodec))
      node3.peerManager.peerStore.connectedness(peerInfo2.peerId) == NotConnected

    await node3.start() # This should trigger a reconnect

    check:
      # Reconnected to node2 after "restart"
      node3.peerManager.peerStore.peers().len == 1
      node3.peerManager.peerStore.peers().anyIt(it.peerId == peerInfo2.peerId)
      node3.peerManager.peerStore.peers().anyIt(it.protos.contains(betaCodec))
      node3.peerManager.peerStore.peers().anyIt(it.protos.contains(stableCodec))
      node3.peerManager.peerStore.connectedness(peerInfo2.peerId) == Connected

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Peer manager connects to all peers supporting a given protocol":
    # Create 4 nodes
    var nodes: seq[WakuNode]
    for i in 0..<4:
      let nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      let node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60860 + i))
      nodes &= node

    # Start them
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Get all peer infos
    let peerInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    # Add all peers (but self) to node 0
    nodes[0].peerManager.addPeer(peerInfos[1], WakuRelayCodec)
    nodes[0].peerManager.addPeer(peerInfos[2], WakuRelayCodec)
    nodes[0].peerManager.addPeer(peerInfos[3], WakuRelayCodec)

    # Attempt to connect to all known peers supporting a given protocol
    await nodes[0].peerManager.reconnectPeers(WakuRelayCodec, protocolMatcher(WakuRelayCodec))

    check:
      # Peerstore track all three peers
      nodes[0].peerManager.peerStore.peers().len == 3

      # All peer ids are correct
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[1].switch.peerInfo.peerId)
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[2].switch.peerInfo.peerId)
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[3].switch.peerInfo.peerId)

      # All peers support the relay protocol
      nodes[0].peerManager.peerStore[ProtoBook][nodes[1].switch.peerInfo.peerId].contains(WakuRelayCodec)
      nodes[0].peerManager.peerStore[ProtoBook][nodes[2].switch.peerInfo.peerId].contains(WakuRelayCodec)
      nodes[0].peerManager.peerStore[ProtoBook][nodes[3].switch.peerInfo.peerId].contains(WakuRelayCodec)

      # All peers are connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[1].switch.peerInfo.peerId] == Connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[2].switch.peerInfo.peerId] == Connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[3].switch.peerInfo.peerId] == Connected

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Peer store keeps track of incoming connections":
    # Create 4 nodes
    var nodes: seq[WakuNode]
    for i in 0..<4:
      let nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      let node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60865 + i))
      nodes &= node

    # Start them
    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Get all peer infos
    let peerInfos = nodes.mapIt(it.switch.peerInfo.toRemotePeerInfo())

    # all nodes connect to peer 0
    discard await nodes[1].peerManager.dialPeer(peerInfos[0], WakuRelayCodec, 2.seconds)
    discard await nodes[2].peerManager.dialPeer(peerInfos[0], WakuRelayCodec, 2.seconds)
    discard await nodes[3].peerManager.dialPeer(peerInfos[0], WakuRelayCodec, 2.seconds)

    check:
      # Peerstore track all three peers
      nodes[0].peerManager.peerStore.peers().len == 3

      # Inbound/Outbound number of peers match
      nodes[0].peerManager.peerStore.getPeersByDirection(Inbound).len == 3
      nodes[0].peerManager.peerStore.getPeersByDirection(Outbound).len == 0
      nodes[1].peerManager.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[1].peerManager.peerStore.getPeersByDirection(Outbound).len == 1
      nodes[2].peerManager.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[2].peerManager.peerStore.getPeersByDirection(Outbound).len == 1
      nodes[3].peerManager.peerStore.getPeersByDirection(Inbound).len == 0
      nodes[3].peerManager.peerStore.getPeersByDirection(Outbound).len == 1

      # All peer ids are correct
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[1].switch.peerInfo.peerId)
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[2].switch.peerInfo.peerId)
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[3].switch.peerInfo.peerId)

      # All peers support the relay protocol
      nodes[0].peerManager.peerStore[ProtoBook][nodes[1].switch.peerInfo.peerId].contains(WakuRelayCodec)
      nodes[0].peerManager.peerStore[ProtoBook][nodes[2].switch.peerInfo.peerId].contains(WakuRelayCodec)
      nodes[0].peerManager.peerStore[ProtoBook][nodes[3].switch.peerInfo.peerId].contains(WakuRelayCodec)

      # All peers are connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[1].switch.peerInfo.peerId] == Connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[2].switch.peerInfo.peerId] == Connected
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[3].switch.peerInfo.peerId] == Connected

      # All peers are Inbound in peer 0
      nodes[0].peerManager.peerStore[DirectionBook][nodes[1].switch.peerInfo.peerId] == Inbound
      nodes[0].peerManager.peerStore[DirectionBook][nodes[2].switch.peerInfo.peerId] == Inbound
      nodes[0].peerManager.peerStore[DirectionBook][nodes[3].switch.peerInfo.peerId] == Inbound

      # All peers have an Outbound connection with peer 0
      nodes[1].peerManager.peerStore[DirectionBook][nodes[0].switch.peerInfo.peerId] == Outbound
      nodes[2].peerManager.peerStore[DirectionBook][nodes[0].switch.peerInfo.peerId] == Outbound
      nodes[3].peerManager.peerStore[DirectionBook][nodes[0].switch.peerInfo.peerId] == Outbound

    await allFutures(nodes.mapIt(it.stop()))
