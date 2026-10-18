{.used.}

import
  results,
  std/[sequtils, strutils, net],
  stew/byteutils,
  testutils/unittests,
  chronos,
  libp2p/crypto/crypto,
  libp2p/crypto/secp,
  libp2p/multiaddress,
  libp2p/switch,
  libp2p/muxers/muxer,
  libp2p/stream/connection,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/mockresolver,
  eth/p2p/discoveryv5/enr,
  eth/net/utils
import
  logos_delivery/kernel/[
    subscription_manager,
    common/topics/content_topic,
    common/topics/pubsub_topic,
    common/message,
    common/peers,
    kernel_lifecycle,
    peer_manager/peer_manager,
    factory/internal_config,
  ],
  ./testlib/wakucore,
  ./testlib/wakunode
suite "Kernel":
  asyncTest "Protocol matcher works as expected":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2)
      shard = DefaultRelayShard
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "hello world".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Setup node 1 with stable codec "/vac/waku/relay/2.0.0"

    (await node1.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node1.protocols.relay.codec = "/vac/waku/relay/2.0.0"

    # Setup node 2 with beta codec "/vac/waku/relay/2.0.0-beta2"

    (await node2.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    node2.protocols.relay.codec = "/vac/waku/relay/2.0.0-beta2"

    check:
      # Check that mounted codecs are actually different
      node1.protocols.relay.codec == "/vac/waku/relay/2.0.0"
      node2.protocols.relay.codec == "/vac/waku/relay/2.0.0-beta2"

    # Now verify that protocol matcher returns `true` and relay works
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    var completionFut = newFuture[bool]()
    proc relayHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      check:
        topic == $shard
        msg.contentTopic == contentTopic
        msg.payload == payload
      completionFut.complete(true)

    ## The following unsubscription is necessary to remove the default relay handler, which is
    ## added when mountRelay is called.
    node2.unsubscribe((kind: PubsubUnsub, topic: $shard)).isOkOr:
      assert false, "Failed to unsubscribe from topic: " & $error

    ## Subscribe to the relay topic to add the custom relay handler defined above
    node2.subscribe((kind: PubsubSub, topic: $shard), relayHandler).isOkOr:
      assert false, "Failed to subscribe to topic"
    await sleepAsync(2000.millis)

    var res = await node1.publish(Opt.some($shard), message)
    assert res.isOk(), $res.error

    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "resolve and connect to dns multiaddrs":
    let resolver = MockResolver.new()

    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]

    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, nameResolver = resolver)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2)

    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await allFutures([node1.start(), node2.start()])

    # Construct DNS multiaddr for node2
    let
      node2PeerId = $(node2.switch.peerInfo.peerId)
      node2Dns4Addr =
        "/dns4/localhost/tcp/" & $node2.boundTcpPort() & "/p2p/" & node2PeerId

    await node1.connectToNodes(@[node2Dns4Addr])

    check:
      node1.switch.connManager.connCount(node2.switch.peerInfo.peerId) == 1

    await allFutures([node1.stop(), node2.stop()])

  asyncTest "Maximum connections can be configured with 20 nodes":
    let
      maxConnections = 20
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(
        nodeKey1, parseIpAddress("127.0.0.1"), Port(0), maxConnections = maxConnections
      )

    # Initialize and start node1
    (await node1.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    # Create an array to hold the other nodes
    var otherNodes: seq[Kernel] = @[]

    # Create and start 20 other nodes
    for _ in 0 ..< maxConnections + 1:
      let
        nodeKey = generateSecp256k1Key()
        kernel = newTestWakuNode(nodeKey, parseIpAddress("127.0.0.1"), Port(0))
      (await kernel.start()).isOkOr:
        raiseAssert "failed to start kernel: " & error
      (await kernel.mountRelay()).isOkOr:
        assert false, "Failed to mount relay"
      otherNodes.add(kernel)

    # Connect all other nodes to node1
    for kernel in otherNodes:
      discard
        await node1.peerManager.connectPeer(kernel.switch.peerInfo.toRemotePeerInfo())

    # Check that the number of connections matches the maxConnections
    check:
      node1.switch.isConnected(otherNodes[0].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[8].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[14].switch.peerInfo.peerId)
      node1.switch.isConnected(otherNodes[20].switch.peerInfo.peerId) == false

    # Stop all nodes
    var stopFutures = @[node1.stop()]
    for kernel in otherNodes:
      stopFutures.add(kernel.stop())
    await allFutures(stopFutures)

  asyncTest "Messages fails with wrong key path":
    let nodeKey1 = generateSecp256k1Key()

    expect ResultDefect:
      # gibberish
      discard newTestWakuNode(
        nodeKey1,
        wsBindPort = Port(8000),
        wssEnabled = true,
        secureKey = "../../waku/node/key_dummy.txt",
      )

  asyncTest "Peer info updates with correct announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(0)
      extIp = Opt.some(getPrimaryIPAddr())
      extPort = Opt.some(Port(61008))
      # tcp-only: asserts exact single listen addr; quic variant below
      kernel =
        newTestWakuNode(nodeKey, bindIp, bindPort, extIp, extPort, quicEnabled = false)

    let
      bindEndpoint = MultiAddress.init(bindIp, tcpProtocol, bindPort)
      announcedEndpoint = MultiAddress.init(extIp.get(), tcpProtocol, extPort.get())

    check:
      # Check that underlying peer info contains only bindIp before starting
      kernel.switch.peerInfo.listenAddrs.len == 1
      kernel.switch.peerInfo.listenAddrs.contains(bindEndpoint)
      # Underlying peer info has not updated addrs before starting
      kernel.switch.peerInfo.addrs.len == 0

      kernel.announcedAddresses.len == 1
      kernel.announcedAddresses.contains(announcedEndpoint)

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    check:
      kernel.started
      # The port-0 listen addr is replaced by the port the OS assigned
      kernel.switch.peerInfo.listenAddrs.len == 1
      $kernel.switch.peerInfo.listenAddrs[0] != $bindEndpoint
      ($kernel.switch.peerInfo.listenAddrs[0]).startsWith("/ip4/0.0.0.0/tcp/")
      # Check that underlying peer info is updated with announced address
      kernel.switch.peerInfo.addrs.len == 1
      kernel.switch.peerInfo.addrs.contains(announcedEndpoint)

    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "Peer info updates with correct announced addresses (QUIC)":
    # dual-stack node announces both tcp and quic-v1
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(0)
      extIp = Opt.some(getPrimaryIPAddr())
      extPort = Opt.some(Port(61008))
      kernel =
        newTestWakuNode(nodeKey, bindIp, bindPort, extIp, extPort, quicEnabled = true)

    let tcpAnnounced = MultiAddress.init(extIp.get(), tcpProtocol, extPort.get())

    check:
      kernel.announcedAddresses.len >= 2
      kernel.announcedAddresses.contains(tcpAnnounced)
      kernel.announcedAddresses.anyIt("/quic-v1" in $it)

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    check:
      kernel.started
      kernel.switch.peerInfo.addrs.len >= 2
      kernel.switch.peerInfo.addrs.contains(tcpAnnounced)
      kernel.switch.peerInfo.addrs.anyIt("/quic-v1" in $it)

    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "Dual-stack nodes connect over QUIC":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, quicEnabled = true)
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, quicEnabled = true)

    await allFutures(node1.start(), node2.start())

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    let conns = node1.switch.connManager.getConnections().getOrDefault(
        node2.switch.peerInfo.peerId
      )
    check conns.len >= 1
    let obAddr = conns[0].connection.observedAddr.valueOr:
      raiseAssert "connection has no observed address"
    check:
      "/udp/" in $obAddr
      "/tcp/" notin $obAddr

    await allFutures(node1.stop(), node2.stop())

  asyncTest "A QUIC-v1 node address given as a string is parsed and dialed":
    ## This is the path of a configured entry node or static node. The address
    ## string goes through parsePeerInfo before the dial.
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), quicEnabled = true)
      node2 = newTestWakuNode(generateSecp256k1Key(), quicEnabled = true)

    await allFutures(node1.start(), node2.start())

    let quicAddrs = node2.switch.peerInfo.addrs.filterIt("/quic-v1" in $it)
    require quicAddrs.len >= 1
    let quicNode = $quicAddrs[0] & "/p2p/" & $node2.switch.peerInfo.peerId

    # The peer manager does this parse first. If the parse is not correct, the
    # peer manager writes "Couldn't parse node info" to the log and does not
    # dial the node.
    let parsed = parsePeerInfo(quicNode)
    if parsed.isErr():
      checkpoint("parsePeerInfo: " & parsed.error)
    check parsed.isOk()

    await node1.connectToNodes(@[quicNode], source = "static")

    let conns = node1.switch.connManager.getConnections().getOrDefault(
        node2.switch.peerInfo.peerId
      )
    check conns.len >= 1
    if conns.len >= 1:
      let obAddr = conns[0].connection.observedAddr.valueOr:
        raiseAssert "connection has no observed address"
      check "/udp/" in $obAddr

    await allFutures(node1.stop(), node2.stop())

  asyncTest "Node can use dns4 in announced addresses":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(61010)
      extIp = Opt.some(getPrimaryIPAddr())
      extPort = Opt.some(Port(61012))
      domainName = "example.com"
      expectedDns4Addr =
        MultiAddress.init("/dns4/" & domainName & "/tcp/" & $(extPort.get())).get()
      kernel = newTestWakuNode(
        nodeKey, bindIp, bindPort, extIp, extPort, dns4DomainName = Opt.some(domainName)
      )

    check:
      # dual-stack also adds a dns4 quic addr, don't assert exact count
      kernel.announcedAddresses.len >= 1
      kernel.announcedAddresses.contains(expectedDns4Addr)

  asyncTest "Node uses dns4 resolved ip in announced addresses if no extIp is provided":
    let
      nodeKey = generateSecp256k1Key()
      bindIp = parseIpAddress("0.0.0.0")
      bindPort = Port(0)

      domainName = "status.im"

    let resolvedIp = (
      await dnsResolve(domainName, defaultTestWakuConf().dnsAddrsNameServers)
    ).valueOr:
      raiseAssert "DNS resolution failed: " & error
    let kernel = newTestWakuNode(
      nodeKey,
      bindIp,
      bindPort,
      extIp = Opt.some(parseIpAddress(resolvedIp)),
      dns4DomainName = Opt.some(domainName),
    )

    var ipStr = ""
    var enrIp = kernel.enr.tryGet("ip", array[4, byte])

    if enrIp.isSome():
      ipStr &= $ipv4(enrIp.get())

    # Check that the IP filled is the one received by the DNS lookup
    # As IPs may change, we check that it's not empty, not the 0 IP and not localhost
    check:
      ipStr.len() > 0
      not ipStr.contains("0.0.0.0")
      not ipStr.contains("127.0.0.1")

  asyncTest "dns4 resolution fails for inexistent and invalid domains":
    let
      inexistentDomain = "thisdomain.doesnot.exist"
      invalidDomain = ""
      expectedError = "Could not resolve IP from DNS: empty response"
      nameServers = defaultTestWakuConf().dnsAddrsNameServers

    let inexistentRes = await dnsResolve(inexistentDomain, nameServers)
    let invalidRes = await dnsResolve(invalidDomain, nameServers)

    check:
      inexistentRes.isErr()
      inexistentRes.error == expectedError
      invalidRes.isErr()
      invalidRes.error == expectedError

  asyncTest "Agent string is set and advertised correctly":
    let
      # custom agent string
      expectedAgentString1 = "node1-agent-string"

      # bump when updating nim-libp2p (2.0.0 default AgentVersion is "nim-libp2p")
      expectedAgentString2 = "nim-libp2p"
    let
      # node with custom agent string
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, agentString = Opt.some(expectedAgentString1))

      # node with default agent string from libp2p
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2)

    (await node1.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    (await node2.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1Agent =
      node2.switch.peerStore[AgentBook][node1.switch.peerInfo.toRemotePeerInfo().peerId]
    let node2Agent =
      node1.switch.peerStore[AgentBook][node2.switch.peerInfo.toRemotePeerInfo().peerId]

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
      node1 = newTestWakuNode(nodeKey1, extMultiAddrs = @[expectedMultiaddress1])

      # node with default multiaddress
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2)

    (await node1.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node1.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    (await node2.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    (await node2.mountRelay()).isOkOr:
      assert false, "Failed to mount relay"

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])
    await node2.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    let node1MultiAddrs = node2.switch.peerStore[AddressBook][
      node1.switch.peerInfo.toRemotePeerInfo().peerId
    ]

    check:
      node1MultiAddrs.contains(expectedMultiaddress1)

    await allFutures(node1.stop(), node2.stop())

  asyncTest "isReady only raises CancelledError and is true without RLN":
    let kernel = newTestWakuNode(generateSecp256k1Key())

    let readyFut = kernel.isReady()
    static:
      doAssert typeof(readyFut) is Future[bool].Raising([CancelledError])

    check:
      await readyFut
