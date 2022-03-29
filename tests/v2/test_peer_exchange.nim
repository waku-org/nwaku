{.used.}

import
  std/[sequtils, options],
  chronicles,
  chronos,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  stew/shims/net,
  testutils/unittests,
  ../../waku/v2/node/wakunode2,
  ../test_helpers

procSuite "Peer Exchange":
  asyncTest "GossipSub (relay) peer exchange":
    ## Tests peer exchange
    
    # Create nodes and ENR. These will be added to the discoverable list
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(60002), sendSignedPeerRecord = true)
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(60003), sendSignedPeerRecord = true)
    
    var
      peerExchangeHandler: RoutingRecordsHandler
      completionFut = newFuture[bool]()
    
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
      ## Handle peers received via gossipsub peer exchange
      let peerRecords = peers.mapIt(it.record.get())
      
      check:
        # Node 3 is informed of node 2 via peer exchange
        peer == node1.switch.peerInfo.peerId
        topic == defaultTopic
        peerRecords.countIt(it.peerId == node2.switch.peerInfo.peerId) == 1
      
      if (not completionFut.completed()):
        completionFut.complete(true)

    peerExchangeHandler = handlePeerExchange

    node1.mountRelay()
    node2.mountRelay()
    node3.mountRelay(peerExchangeHandler = some(peerExchangeHandler))

    # Ensure that node1 prunes all peers after the first connection
    node1.wakuRelay.parameters.dHigh = 1

    await allFutures([node1.start(), node2.start(), node3.start()])
    
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    await node3.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
