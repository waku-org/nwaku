{.used.}

import std/options, chronos, testutils/unittests, libp2p/builders

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
      node3 = newTestWakuNode(
        generateSecp256k1Key(),
        parseIpAddress("0.0.0.0"),
        Port(0),
        clusterId = clusterId,
      )

    await allFutures(
      [node1.mountRendezvous(), node2.mountRendezvous(), node3.mountRendezvous()]
    )
    await allFutures([node1.start(), node2.start(), node3.start()])

    let peerInfo1 = node1.switch.peerInfo.toRemotePeerInfo()
    let peerInfo2 = node2.switch.peerInfo.toRemotePeerInfo()
    let peerInfo3 = node3.switch.peerInfo.toRemotePeerInfo()

    node1.peerManager.addPeer(peerInfo2)
    node2.peerManager.addPeer(peerInfo1)
    node2.peerManager.addPeer(peerInfo3)
    node3.peerManager.addPeer(peerInfo2)

    let namespace = "test/name/space"

    let res = await node1.wakuRendezvous.batchAdvertise(
      namespace, 60.seconds, @[peerInfo2.peerId]
    )
    assert res.isOk(), $res.error

    let response =
      await node3.wakuRendezvous.batchRequest(namespace, 1, @[peerInfo2.peerId])
    assert response.isOk(), $response.error
    let records = response.get()

    check:
      records.len == 1
      records[0].peerId == peerInfo1.peerId
