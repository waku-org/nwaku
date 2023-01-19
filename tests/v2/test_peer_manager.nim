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
    # Create 2 nodes
    let nodes = toSeq(0..<2).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountRelay()))

    # Dial node2 from node1
    let conn = (await nodes[0].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec)).get()

    # Check connection
    check:
      conn.activity
      conn.peerId == nodes[1].peerInfo.peerId

    # Check that node2 is being managed in node1
    check:
      nodes[0].peerManager.peerStore.peers().anyIt(it.peerId == nodes[1].peerInfo.peerId)

    # Check connectedness
    check:
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == Connectedness.Connected

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Dialing fails gracefully":
    # Create 2 nodes
    let nodes = toSeq(0..<2).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    await nodes[0].start()
    await nodes[0].mountRelay()

    # Purposefully don't start node2

    # Dial node2 from node1
    let connOpt = await nodes[1].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)

    # Check connection failed gracefully
    check:
      connOpt.isNone()

    await nodes[0].stop()

  asyncTest "Adding, selecting and filtering peers work":
    let
      node = WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0))
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
    # Create 2 nodes
    let nodes = toSeq(0..<2).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    await nodes[0].start()
    # Do not start node2

    await allFutures(nodes.mapIt(it.mountRelay()))

    # Test default connectedness for new peers
    nodes[0].peerManager.addPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec)
    check:
      # No information about node2's connectedness
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == NotConnected

    # Purposefully don't start node2
    # Attempt dialing node2 from node1
    discard await nodes[0].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Cannot connect to node2
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == CannotConnect

    # Successful connection
    await nodes[1].start()
    discard await nodes[0].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec, 2.seconds)
    check:
      # Currently connected to node2
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == Connected

    # Stop node. Gracefully disconnect from all peers.
    await nodes[0].stop()
    check:
      # Not currently connected to node2, but had recent, successful connection.
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == CanConnect

    await nodes[1].stop()

  asyncTest "Peer manager updates failed peers correctly":
    # Create 2 nodes
    let nodes = toSeq(0..<2).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    await nodes[0].start()
    await nodes[0].mountRelay()
    nodes[0].peerManager.addPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec)

    # Set a low backoff to speed up test
    nodes[0].peerManager.initialBackoffInSec = 2

    # node2 is not started, so dialing will fail
    let conn1 = await nodes[0].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec, 1.seconds)
    check:
      # Cannot connect to node2
      nodes[0].peerManager.peerStore.connectedness(nodes[1].peerInfo.peerId) == CannotConnect
      nodes[0].peerManager.peerStore[ConnectionBook][nodes[1].peerInfo.peerId] == CannotConnect
      nodes[0].peerManager.peerStore[NumberFailedConnBook][nodes[1].peerInfo.peerId] == 1

      # And the connection failed
      conn1.isNone() == true

      # Right after failing there is a backoff period
      nodes[0].peerManager.peerStore.canBeConnected(nodes[1].peerInfo.peerId, nodes[0].peerManager.initialBackoffInSec) == false

    # We wait the first backoff period
    await sleepAsync(2.seconds)

    # And backoff period is over
    check:
      nodes[0].peerManager.peerStore.canBeConnected(nodes[1].peerInfo.peerId, nodes[0].peerManager.initialBackoffInSec) == true

    await nodes[1].start()
    await nodes[1].mountRelay()

    # Now we can connect and failed count is reset
    let conn2 = await nodes[0].peerManager.dialPeer(nodes[1].peerInfo.toRemotePeerInfo(), WakuRelayCodec, 1.seconds)
    check:
      conn2.isNone() == false
      nodes[0].peerManager.peerStore[NumberFailedConnBook][nodes[1].peerInfo.peerId] == 0

    await allFutures(nodes.mapIt(it.stop()))

  asyncTest "Peer manager can use persistent storage and survive restarts":
    let
      database = SqliteDatabase.new(":memory:")[]
      storage = WakuPeerStorage.new(database)[]
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
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
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0), peerStorage = storage)

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
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0), peerStorage = storage)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))
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
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"), Port(0), peerStorage = storage)

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
    let nodes = toSeq(0..<4).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

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
    let nodes = toSeq(0..<4).mapIt(WakuNode.new(generateKey(), ValidIpAddress.init("0.0.0.0"), Port(0)))

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
