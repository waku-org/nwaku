{.used.}

import
  std/tables,
  chronicles,
  chronos,
  testutils/unittests,
  stew/shims/net,
  libp2p/crypto/crypto,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/node/wakunode2,
  ../test_helpers

procSuite "Waku Discovery v5":
  asyncTest "Waku Discovery v5 end-to-end":
    ## Tests integrated discovery v5
    
    # Create nodes and ENR. These will be added to the discoverable list
    let
      bindIp = ValidIpAddress.init("0.0.0.0")

      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort1 = Port(60000)
      nodeUdpPort1 = Port(9000)
      node1 = WakuNode.new(nodeKey1, bindIp, nodeTcpPort1)
      
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort2 = Port(60002)
      nodeUdpPort2 = Port(9002)
      node2 = WakuNode.new(nodeKey2, bindIp, nodeTcpPort2)

      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort3 = Port(60004)
      nodeUdpPort3 = Port(9004)
      node3 = WakuNode.new(nodeKey3, bindIp, nodeTcpPort3)
    
    # Mount discv5
    node1.wakuDiscv5 = WakuDiscoveryV5.new(
        some(bindIp), some(nodeTcpPort1), some(nodeUdpPort1),
        bindIp,
        nodeUdpPort1,
        @[],
        false,
        keys.PrivateKey(nodeKey1.skkey),
        [], # Empty enr fields, for now
        node1.rng
      )
    
    node2.wakuDiscv5 = WakuDiscoveryV5.new(
        some(bindIp), some(nodeTcpPort2), some(nodeUdpPort2),
        bindIp,
        nodeUdpPort2,
        @[node1.wakuDiscv5.protocol.localNode.record.toURI()], # Bootstrap with node1
        false,
        keys.PrivateKey(nodeKey2.skkey),
        [], # Empty enr fields, for now
        node2.rng
      )
    
    node3.wakuDiscv5 = WakuDiscoveryV5.new(
        some(bindIp), some(nodeTcpPort3), some(nodeUdpPort3),
        bindIp,
        nodeUdpPort3,
        @[node2.wakuDiscv5.protocol.localNode.record.toURI()], # Bootstrap with node2
        false,
        keys.PrivateKey(nodeKey3.skkey),
        [], # Empty enr fields, for now
        node3.rng
      )

    node1.mountRelay()
    node2.mountRelay()
    node3.mountRelay()

    await allFutures([node1.start(), node2.start(), node3.start()])

    await allFutures([node1.startDiscv5(), node2.startDiscv5(), node3.startDiscv5()])

    await sleepAsync(2000.millis)

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
