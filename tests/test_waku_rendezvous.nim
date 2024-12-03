{.used.}

import chronos, testutils/unittests, libp2p/builders

import
  waku/waku_core/peers,
  waku/node/waku_node,
  waku/node/peer_manager/peer_manager,
  waku/waku_rendezvous/protocol,
  ./testlib/[wakucore, wakunode]

procSuite "Waku Rendezvous":
  asyncTest "Simple remote test":
    let
      clusterId = 10.uint16
      node1 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )
      node2 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )

    # Start nodes
    await allFutures([node1.start(), node2.start()])

    let remotePeerInfo1 = node1.switch.peerInfo.toRemotePeerInfo()
    let remotePeerInfo2 = node2.switch.peerInfo.toRemotePeerInfo()

    node2.peerManager.addPeer(remotePeerInfo1)

    let namespace = "test/name/space"

    let res = await node2.wakuRendezvous.batchAdvertise(
      namespace, peers = @[remotePeerInfo1.peerId]
    )
    assert res.isOk(), $res.error

    let response =
      await node2.wakuRendezvous.batchRequest(namespace, 1, @[remotePeerInfo1.peerId])
    assert response.isOk(), $response.error

    let records = response.get()

    check:
      records[0].peerId == remotePeerInfo2.peerId
