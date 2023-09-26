{.used.}

import
  std/sequtils,
  stew/byteutils,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/mockresolver,
  eth/p2p/discoveryv5/enr
import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ../../waku/node/peer_manager,
  ../../waku/waku_relay,
  ../../waku/waku_peer_exchange,
  ./testlib/wakucore,
  ./testlib/wakunode


suite "WakuNode":

  asyncTest "Protocol matcher works as expected":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61000))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61002))
      pubSubTopic = "/waku/2/default-waku/proto"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Setup node 1 with stable codec "/vac/waku/relay/2.0.0"

    await node1.start()
    await node1.mountRelay(@[pubSubTopic])
    node1.wakuRelay.codec = "/vac/waku/relay/2.0.0"

    # Setup node 2 with beta codec "/vac/waku/relay/2.0.0-beta2"

    await node2.start()
    await node2.mountRelay(@[pubSubTopic])
    node2.wakuRelay.codec = "/vac/waku/relay/2.0.0-beta2"

    check:
      # Check that mounted codecs are actually different
      node1.wakuRelay.codec ==  "/vac/waku/relay/2.0.0"
      node2.wakuRelay.codec == "/vac/waku/relay/2.0.0-beta2"

    # Now verify that protocol matcher returns `true` and relay works
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
      check:
        topic == pubSubTopic
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    node2.subscribe((kind: PubsubSub, topic: pubsubTopic), some(relayHandler))
    await sleepAsync(2000.millis)

    await node1.publish(some(pubSubTopic), message)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "resolve and connect to dns multiaddrs":
    let resolver = MockResolver.new()

    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]

    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61020), nameResolver = resolver)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61022))

    # Construct DNS multiaddr for node2
    let
      node2PeerId = $(node2.switch.peerInfo.peerId)
      node2Dns4Addr = "/dns4/localhost/tcp/61022/p2p/" & node2PeerId

    await node1.mountRelay()
    await node2.mountRelay()

    await allFutures([node1.start(), node2.start()])

    await node1.connectToNodes(@[node2Dns4Addr])

    check:
      node1.switch.connManager.connCount(node2.switch.peerInfo.peerId) == 1

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Maximum connections can be configured":
    let
      maxConnections = 2
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010), maxConnections = maxConnections)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = generateSecp256k1Key()
      node3 = newTestWakuNode(nodeKey3, ValidIpAddress.init("0.0.0.0"),
        Port(60013))

    check:
      # Sanity check, to verify config was applied
      node1.switch.connManager.inSema.size == maxConnections

    # Node with connection limit set to 1
    await node1.start()
    await node1.mountRelay()

    # Remote node 1
    await node2.start()
    await node2.mountRelay()

    # Remote node 2
    await node3.start()
    await node3.mountRelay()

    discard await node1.peerManager.connectRelay(node2.switch.peerInfo.toRemotePeerInfo())
    await sleepAsync(3.seconds)
    discard await node1.peerManager.connectRelay(node3.switch.peerInfo.toRemotePeerInfo())

    check:
      # Verify that only the first connection succeeded
      node1.switch.isConnected(node2.switch.peerInfo.peerId)
      node1.switch.isConnected(node3.switch.peerInfo.peerId) == false

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Messages fails with wrong key path":
    let nodeKey1 = generateSecp256k1Key()

    expect ResultDefect:
      # gibberish
      discard newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(61004),
        wsBindPort = Port(8000),
        wssEnabled = true,
        secureKey = "../../waku/node/key_dummy.txt")

  asyncTest "Peer info updates with correct announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = ValidIpAddress.init("0.0.0.0")
      bindPort = Port(61006)
      extIp = some(ValidIpAddress.init("127.0.0.1"))
      extPort = some(Port(61008))
      node = newTestWakuNode(
        nodeKey,
        bindIp, bindPort,
        extIp, extPort)

    let
      bindEndpoint = MultiAddress.init(bindIp, tcpProtocol, bindPort)
      announcedEndpoint = MultiAddress.init(extIp.get(), tcpProtocol, extPort.get())

    check:
      # Check that underlying peer info contains only bindIp before starting
      node.switch.peerInfo.listenAddrs.len == 1
      node.switch.peerInfo.listenAddrs.contains(bindEndpoint)
      # Underlying peer info has not updated addrs before starting
      node.switch.peerInfo.addrs.len == 0

      node.announcedAddresses.len == 1
      node.announcedAddresses.contains(announcedEndpoint)

    await node.start()

    check:
      node.started
      # Underlying peer info listenAddrs has not changed
      node.switch.peerInfo.listenAddrs.len == 1
      node.switch.peerInfo.listenAddrs.contains(bindEndpoint)
      # Check that underlying peer info is updated with announced address
      node.switch.peerInfo.addrs.len == 1
      node.switch.peerInfo.addrs.contains(announcedEndpoint)

    await node.stop()

  asyncTest "Node can use dns4 in announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = ValidIpAddress.init("0.0.0.0")
      bindPort = Port(61010)
      extIp = some(ValidIpAddress.init("127.0.0.1"))
      extPort = some(Port(61012))
      domainName = "example.com"
      expectedDns4Addr = MultiAddress.init("/dns4/" & domainName & "/tcp/" & $(extPort.get())).get()
      node = newTestWakuNode(
        nodeKey,
        bindIp, bindPort,
        extIp, extPort,
        dns4DomainName = some(domainName))

    check:
      node.announcedAddresses.len == 1
      node.announcedAddresses.contains(expectedDns4Addr)


  asyncTest "Agent string is set and advertised correctly":
    let
      # custom agent string
      expectedAgentString1 = "node1-agent-string"

      # bump when updating nim-libp2p
      expectedAgentString2 = "nim-libp2p/0.0.1"
    let
      # node with custom agent string
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61014),
                           agentString = some(expectedAgentString1))

      # node with default agent string from libp2p
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61016))

    await node1.start()
    await node1.mountRelay()

    await node2.start()
    await node2.mountRelay()

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1Agent = node2.switch.peerStore[AgentBook][node1.switch.peerInfo.toRemotePeerInfo().peerId]
    let node2Agent = node1.switch.peerStore[AgentBook][node2.switch.peerInfo.toRemotePeerInfo().peerId]

    check:
      node1Agent == expectedAgentString1
      node2Agent == expectedAgentString2

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Custom multiaddresses are set and advertised correctly":
    let
      # custom multiaddress
      expectedMultiaddress1 = MultiAddress.init("/ip4/200.200.200.200/tcp/1234").get()

    # Note: this could have been done with a single node, but it is useful to
    # have two nodes to check that the multiaddress is advertised correctly
    let
      # node with custom multiaddress
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61018),
                           extMultiAddrs = @[expectedMultiaddress1])

      # node with default multiaddress
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61020))

    await node1.start()
    await node1.mountRelay()

    await node2.start()
    await node2.mountRelay()

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1MultiAddrs = node2.switch.peerStore[AddressBook][node1.switch.peerInfo.toRemotePeerInfo().peerId]

    check:
      node1MultiAddrs.contains(expectedMultiaddress1)

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Function fetchPeerExchangePeers succesfully exchanges px peers":
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    # Start and mount peer exchange
    await allFutures([node1.start(), node2.start()])
    await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

    # Mock that we discovered a node (to avoid running discv5)
    var enr = enr.Record()
    require enr.fromUri("enr:-Iu4QGNuTvNRulF3A4Kb9YHiIXLr0z_CpvWkWjWKU-o95zUPR_In02AWek4nsSk7G_-YDcaT4bDRPzt5JIWvFqkXSNcBgmlkgnY0gmlwhE0WsGeJc2VjcDI1NmsxoQKp9VzU2FAh7fwOwSpg1M_Ekz4zzl0Fpbg6po2ZwgVwQYN0Y3CC6mCFd2FrdTIB")
    node2.wakuPeerExchange.enrCache.add(enr)

    # Set node2 as service peer (default one) for px protocol
    node1.peerManager.addServicePeer(node2.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec)

    # Request 1 peer from peer exchange protocol
    await node1.fetchPeerExchangePeers(1)

    # Check that the peer ended up in the peerstore
    let rpInfo = enr.toRemotePeerInfo.get()
    check:
      node1.peerManager.peerStore.peers.anyIt(it.peerId == rpInfo.peerId)
      node1.peerManager.peerStore.peers.anyIt(it.addrs == rpInfo.addrs)
