{.used.}

import
  std/options,
  chronos,
  testutils/unittests,
  libp2p/builders,
  libp2p/protocols/rendezvous

import
  waku/waku_core/peers,
  waku/waku_core/codecs,
  waku/node/waku_node,
  waku/node/peer_manager/peer_manager,
  waku/waku_rendezvous/protocol,
  waku/waku_rendezvous/common,
  waku/waku_rendezvous/waku_peer_record,
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
      [
        node1.mountRendezvous(clusterId),
        node2.mountRendezvous(clusterId),
        node3.mountRendezvous(clusterId),
      ]
    )
    await allFutures([node1.start(), node2.start(), node3.start()])

    let peerInfo1 = node1.switch.peerInfo.toRemotePeerInfo()
    let peerInfo2 = node2.switch.peerInfo.toRemotePeerInfo()
    let peerInfo3 = node3.switch.peerInfo.toRemotePeerInfo()

    node1.peerManager.addPeer(peerInfo2)
    node2.peerManager.addPeer(peerInfo1)
    node2.peerManager.addPeer(peerInfo3)
    node3.peerManager.addPeer(peerInfo2)

    let res = await node1.wakuRendezvous.advertiseAll()
    assert res.isOk(), $res.error
    # Rendezvous Request API requires dialing first
    let connOpt =
      await node3.peerManager.dialPeer(peerInfo2.peerId, WakuRendezVousCodec)
    require:
      connOpt.isSome

    var records: seq[WakuPeerRecord]
    try:
      records = await rendezvous.request[WakuPeerRecord](
        node3.wakuRendezvous,
        Opt.some(computeMixNamespace(clusterId)),
        Opt.some(1),
        Opt.some(@[peerInfo2.peerId]),
      )
    except CatchableError as e:
      assert false, "Request failed with exception: " & e.msg

    check:
      records.len == 1
      records[0].peerId == peerInfo1.peerId
      #records[0].mixPubKey == $node1.wakuMix.pubKey
