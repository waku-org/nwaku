{.used.}

import
  std/tables,
  chronicles,
  chronos,
  testutils/unittests,
  stew/byteutils,
  stew/shims/net,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/waku_node,
  ../test_helpers

procSuite "Waku Discovery v5":
  asyncTest "Waku Discovery v5 end-to-end":
    ## Tests integrated discovery v5
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")

      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort1 = Port(61500)
      nodeUdpPort1 = Port(9000)
      node1 = WakuNode.new(nodeKey1, bindIp, nodeTcpPort1)
      
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort2 = Port(61502)
      nodeUdpPort2 = Port(9002)
      node2 = WakuNode.new(nodeKey2, bindIp, nodeTcpPort2)

      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort3 = Port(61504)
      nodeUdpPort3 = Port(9004)
      node3 = WakuNode.new(nodeKey3, bindIp, nodeTcpPort3)

      flags = initWakuFlags(lightpush = false,
                            filter = false,
                            store = false,
                            relay = true)

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
        newSeq[string](),
        false,
        keys.PrivateKey(nodeKey1.skkey),
        flags,
        [], # Empty enr fields, for now
        node1.rng
      )
    
    node2.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort2), some(nodeUdpPort2),
        bindIp,
        nodeUdpPort2,
        @[node1.wakuDiscv5.protocol.localNode.record.toURI()], # Bootstrap with node1
        false,
        keys.PrivateKey(nodeKey2.skkey),
        flags,
        [], # Empty enr fields, for now
        node2.rng
      )
    
    node3.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort3), some(nodeUdpPort3),
        bindIp,
        nodeUdpPort3,
        @[node2.wakuDiscv5.protocol.localNode.record.toURI()], # Bootstrap with node2
        false,
        keys.PrivateKey(nodeKey3.skkey),
        flags,
        [], # Empty enr fields, for now
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
    #   let msg = WakuMessage.init(data)
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
