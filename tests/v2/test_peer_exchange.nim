{.used.}

import
  std/[sequtils, options],
  stew/shims/net,
  testutils/unittests,
  chronos,
  libp2p/peerid,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/utils/peers,
  ../test_helpers,
  ./testlib/common

procSuite "Peer Exchange":
  asyncTest "GossipSub (relay) peer exchange":
    ## Tests peer exchange
    
    # Create nodes and ENR. These will be added to the discoverable list
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.new(nodeKey1, bindIp, Port(61100))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.new(nodeKey2, bindIp, Port(61102), sendSignedPeerRecord = true)
      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node3 = WakuNode.new(nodeKey3, bindIp, Port(61103), sendSignedPeerRecord = true)
    
    var
      peerExchangeHandler, emptyHandler: RoutingRecordsHandler
      completionFut = newFuture[bool]()
    
    proc ignorePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
      discard
    
    proc handlePeerExchange(peer: PeerId, topic: string,
                            peers: seq[RoutingRecordsPair]) {.gcsafe, raises: [Defect].} =
      ## Handle peers received via gossipsub peer exchange
      let peerRecords = peers.mapIt(it.record.get())
      
      check:
        # Node 3 is informed of node 2 via peer exchange
        peer == node1.switch.peerInfo.peerId
        topic == DefaultPubsubTopic
        peerRecords.countIt(it.peerId == node2.switch.peerInfo.peerId) == 1
      
      if (not completionFut.completed()):
        completionFut.complete(true)

    peerExchangeHandler = handlePeerExchange
    emptyHandler = ignorePeerExchange

    await node1.mountRelay(peerExchangeHandler = some(emptyHandler))
    await node2.mountRelay(peerExchangeHandler = some(emptyHandler))
    await node3.mountRelay(peerExchangeHandler = some(peerExchangeHandler))

    # Ensure that node1 prunes all peers after the first connection
    node1.wakuRelay.parameters.dHigh = 1

    await allFutures([node1.start(), node2.start(), node3.start()])
    
    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    await node3.connectToNodes(@[node1.switch.peerInfo.toRemotePeerInfo()])

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
