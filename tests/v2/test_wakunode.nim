{.used.}

import
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
  libp2p/nameresolving/mockresolver
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_relay,
  ../../waku/v2/utils/peers


procSuite "WakuNode":
  let rng = crypto.newRng()
   
  asyncTest "Protocol matcher works as expected":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61002))
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
    proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.init(data)
      if msg.isOk():
        let val = msg.value()
        check:
          topic == pubSubTopic
          val.contentTopic == contentTopic
          val.payload == payload
      completionFut.complete(true)

    node2.subscribe(pubSubTopic, relayHandler)
    await sleepAsync(2000.millis)

    await node1.publish(pubSubTopic, message)
    await sleepAsync(2000.millis)

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures(node1.stop(), node2.stop())

  asyncTest "resolve and connect to dns multiaddrs":
    let resolver = MockResolver.new()

    resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]

    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61020), nameResolver = resolver)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61022))

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
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60010), maxConnections = maxConnections)
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60012))
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, ValidIpAddress.init("0.0.0.0"),
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

    discard await node1.peerManager.dialPeer(node2.switch.peerInfo.toRemotePeerInfo(), WakuRelayCodec)
    await sleepAsync(3.seconds)
    discard await node1.peerManager.dialPeer(node3.switch.peerInfo.toRemotePeerInfo(), WakuRelayCodec)

    check:
      # Verify that only the first connection succeeded
      node1.switch.isConnected(node2.switch.peerInfo.peerId)
      node1.switch.isConnected(node3.switch.peerInfo.peerId) == false

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Messages fails with wrong key path":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]

    expect IOError:
      # gibberish
      discard WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        bindPort = Port(61004), 
        wsBindPort = Port(8000), 
        wssEnabled = true, 
        secureKey = "../../waku/v2/node/key_dummy.txt")

  asyncTest "Peer info updates with correct announced addresses":
    let
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      bindIp = ValidIpAddress.init("0.0.0.0")
      bindPort = Port(61006)
      extIp = some(ValidIpAddress.init("127.0.0.1"))
      extPort = some(Port(61008))
      node = WakuNode.new(
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
      nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
      bindIp = ValidIpAddress.init("0.0.0.0")
      bindPort = Port(61010)
      extIp = some(ValidIpAddress.init("127.0.0.1"))
      extPort = some(Port(61012))
      domainName = "example.com"
      expectedDns4Addr = MultiAddress.init("/dns4/" & domainName & "/tcp/" & $(extPort.get())).get()
      node = WakuNode.new(
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
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(61014),
                           agentString = some(expectedAgentString1))

      # node with default agent string from libp2p
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(61016))

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