import
  std/[unittest, options, sets, tables, sequtils],
  stew/shims/net as stewNet,
  json_rpc/[rpcserver, rpcclient],
  eth/[keys, rlp], eth/common/eth_types,
  libp2p/[standard_setup, switch, multiaddress],
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/message,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/protocol/waku_relay,
  ../test_helpers

procSuite "Peer Manager":
  asyncTest "Peer dialing":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"),
        Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"),
        Port(60002))
      peerInfo2 = node2.peerInfo
    
    await allFutures([node1.start(), node2.start()])

    node1.mountRelay()
    node2.mountRelay()

    # Dial node2 from node1
    let conn = await node1.peerManager.dialPeer(peerInfo2, WakuRelayCodec)

    # Check connection
    check:
      conn.activity
      conn.peerInfo.peerId == peerInfo2.peerId
    
    # Check that node2 is being managed in node1
    check:
      node1.peerManager.peers().anyIt(it.peerId == peerInfo2.peerId)

    # Check connectedness
    check:
      node1.peerManager.connectedness(peerInfo2.peerId)

