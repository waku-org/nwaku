{.used.}

import
  std/[options, sequtils, tables],
  testutils/unittests,
  chronos,
  chronicles,
  stew/shims/net,
  libp2p/switch,
  libp2p/peerId,
  libp2p/crypto/crypto,
  libp2p/multistream,
  libp2p/muxers/muxer,
  eth/keys,
  eth/p2p/discoveryv5/enr
import
  ../../waku/waku_node,
  ../../waku/node/peer_manager,
  ../../waku/waku_discv5,
  ../../waku/waku_metadata,
  ./testlib/wakucore,
  ./testlib/wakunode


procSuite "Waku Metadata Protocol":

  # TODO: Add tests with shards when ready
  asyncTest "request() returns the supported metadata of the peer":
    let clusterId = 10.uint32
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0), clusterId = clusterId)
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0), clusterId = clusterId)

    # Start nodes
    await allFutures([node1.start(), node2.start()])

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(node1.switch.peerInfo.toRemotePeerInfo(), WakuMetadataCodec)
    require:
      connOpt.isSome

    # Request metadata
    let response1 = await node2.wakuMetadata.request(connOpt.get())

    # Check the response or dont even continue
    require:
      response1.isOk

    check:
      response1.get().clusterId.get() == clusterId
