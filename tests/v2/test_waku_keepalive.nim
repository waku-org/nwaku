{.used.}

import
  std/[options, tables, sets],
  testutils/unittests, chronos, chronicles,
  stew/shims/net as stewNet,
  libp2p/switch,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/[bufferstream, connection],
  libp2p/crypto/crypto,
  libp2p/multistream,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/protocol/waku_keepalive/waku_keepalive,
  ../test_helpers, ./utils

procSuite "Waku Keepalive":

  asyncTest "handle keepalive":
    let
      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node1 = WakuNode.init(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(60000))
      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      node2 = WakuNode.init(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(60002))

    await node1.start()
    node1.mountRelay()
    node1.mountKeepalive()

    await node2.start()
    node2.mountRelay()
    node2.mountKeepalive()

    await node1.connectToNodes(@[node2.peerInfo])

    var completionFut = newFuture[bool]()

    proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
      debug "WakuKeepalive message received"
      
      check:
        proto == waku_keepalive.WakuKeepaliveCodec
      
      completionFut.complete(true)
    
    node2.wakuKeepalive.handler = handle

    node1.startKeepalive()

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await allFutures([node1.stop(), node2.stop()])
