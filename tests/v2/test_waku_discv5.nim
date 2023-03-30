{.used.}

import
  chronos,
  chronicles,
  testutils/unittests,
  stew/byteutils,
  stew/shims/net,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_discv5,
  ./testlib/common,
  ./testlib/waku2

procSuite "Waku Discovery v5":
  asyncTest "Waku Discovery v5 end-to-end":
    ## Tests integrated discovery v5
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")

      nodeKey1 = generateSecp256k1Key()
      nodeTcpPort1 = Port(61500)
      nodeUdpPort1 = Port(9000)
      node1 = WakuNode.new(nodeKey1, bindIp, nodeTcpPort1)

      nodeKey2 = generateSecp256k1Key()
      nodeTcpPort2 = Port(61502)
      nodeUdpPort2 = Port(9002)
      node2 = WakuNode.new(nodeKey2, bindIp, nodeTcpPort2)

      nodeKey3 = generateSecp256k1Key()
      nodeTcpPort3 = Port(61504)
      nodeUdpPort3 = Port(9004)
      node3 = WakuNode.new(nodeKey3, bindIp, nodeTcpPort3)

      flags = CapabilitiesBitfield.init(
                lightpush = false,
                filter = false,
                store = false,
                relay = true
              )

      # E2E relay test paramaters
      pubSubTopic = "/waku/2/default-waku/proto"
      contentTopic = ContentTopic("/waku/2/default-content/proto")
      payload = "Can you see me?".toBytes()
      message = WakuMessage(payload: payload, contentTopic: contentTopic)

    # Mount discv5
    node1.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort1), some(nodeUdpPort1),
        bindIp,
        nodeUdpPort1,
        newSeq[enr.Record](),
        false,
        keys.PrivateKey(nodeKey1.skkey),
        flags,
        newSeq[MultiAddress](), # Empty multiaddr fields, for now
        node1.rng
      )

    node2.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort2), some(nodeUdpPort2),
        bindIp,
        nodeUdpPort2,
        @[node1.wakuDiscv5.protocol.localNode.record], # Bootstrap with node1
        false,
        keys.PrivateKey(nodeKey2.skkey),
        flags,
        newSeq[MultiAddress](), # Empty multiaddr fields, for now
        node2.rng
      )

    node3.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort3), some(nodeUdpPort3),
        bindIp,
        nodeUdpPort3,
        @[node2.wakuDiscv5.protocol.localNode.record], # Bootstrap with node2
        false,
        keys.PrivateKey(nodeKey3.skkey),
        flags,
        newSeq[MultiAddress](), # Empty multiaddr fields, for now
        node3.rng
      )

    await node1.mountRelay()
    await node2.mountRelay()
    await node3.mountRelay()

    await allFutures([node1.start(), node2.start(), node3.start()])

    await allFutures([node1.startDiscv5(), node2.startDiscv5(), node3.startDiscv5()])

    await sleepAsync(3000.millis) # Give the algorithm some time to work its magic
    check:
      node1.wakuDiscv5.protocol.nodesDiscovered > 0
      node2.wakuDiscv5.protocol.nodesDiscovered > 0
      node3.wakuDiscv5.protocol.nodesDiscovered > 0

    # Let's see if we can deliver a message end-to-end
    # var completionFut = newFuture[bool]()
    # proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    #   let msg = WakuMessage.decode(data)
    #   if msg.isOk():
    #     let val = msg.value()
    #     check:
    #       topic == pubSubTopic
    #       val.contentTopic == contentTopic
    #       val.payload == payload
    #   completionFut.complete(true)

    # node3.subscribe(pubSubTopic, relayHandler)
    # await sleepAsync(2000.millis)

    # await node1.publish(pubSubTopic, message)

    # check:
    #   (await completionFut.withTimeout(6.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])

  asyncTest "Custom multiaddresses are advertised correctly":
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")
      expectedMultiAddr = MultiAddress.init("/ip4/200.200.200.200/tcp/9000/wss").tryGet()

      flags = CapabilitiesBitfield.init(
                lightpush = false,
                filter = false,
                store = false,
                relay = true
              )

      nodeTcpPort1 = Port(9010)
      nodeUdpPort1 = Port(9012)
      node1Key = generateSecp256k1Key()
      node1NetConfig = NetConfig.init(bindIp = bindIp,
                                      extIp = some(extIp),
                                      extPort = some(nodeTcpPort1),
                                      bindPort = nodeTcpPort1,
                                      extmultiAddrs = @[expectedMultiAddr],
                                      wakuFlags = some(flags),
                                      discv5UdpPort = some(nodeUdpPort1))
      node1discV5 = WakuDiscoveryV5.new(extIp = node1NetConfig.extIp,
                                        extTcpPort = node1NetConfig.extPort,
                                        extUdpPort = node1NetConfig.discv5UdpPort,
                                        bindIp = node1NetConfig.bindIp,
                                        discv5UdpPort = node1NetConfig.discv5UdpPort.get(),
                                        privateKey = keys.PrivateKey(node1Key.skkey),
                                        multiaddrs = node1NetConfig.enrMultiaddrs,
                                        flags = node1NetConfig.wakuFlags.get(),
                                        rng = rng)
      node1 = WakuNode.new(nodekey = node1Key,
                           netConfig = node1NetConfig,
                           wakuDiscv5 = some(node1discV5),
                           rng = rng)


      nodeTcpPort2 = Port(9014)
      nodeUdpPort2 = Port(9016)
      node2Key = generateSecp256k1Key()
      node2NetConfig = NetConfig.init(bindIp = bindIp,
                                      extIp = some(extIp),
                                      extPort = some(nodeTcpPort2),
                                      bindPort = nodeTcpPort2,
                                      wakuFlags = some(flags),
                                      discv5UdpPort = some(nodeUdpPort2))
      node2discV5 = WakuDiscoveryV5.new(extIp = node2NetConfig.extIp,
                                        extTcpPort = node2NetConfig.extPort,
                                        extUdpPort = node2NetConfig.discv5UdpPort,
                                        bindIp = node2NetConfig.bindIp,
                                        discv5UdpPort = node2NetConfig.discv5UdpPort.get(),
                                        bootstrapEnrs = @[node1.wakuDiscv5.protocol.localNode.record],
                                        privateKey = keys.PrivateKey(node2Key.skkey),
                                        flags = node2NetConfig.wakuFlags.get(),
                                        rng = rng)
      node2 = WakuNode.new(nodeKey = node2Key,
                           netConfig = node2NetConfig,
                           wakuDiscv5 = some(node2discV5))

    await allFutures([node1.start(), node2.start()])

    await allFutures([node1.startDiscv5(), node2.startDiscv5()])

    await sleepAsync(3000.millis) # Give the algorithm some time to work its magic

    let node1Enr = node2.wakuDiscv5.protocol.routingTable.buckets[0].nodes[0].record
    let multiaddrs = node1Enr.toTyped().get().multiaddrs.get()

    check:
      node1.wakuDiscv5.protocol.nodesDiscovered > 0
      node2.wakuDiscv5.protocol.nodesDiscovered > 0
      multiaddrs.contains(expectedMultiAddr)

