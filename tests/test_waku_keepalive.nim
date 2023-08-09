{.used.}

import
  std/options,
  stew/shims/net as stewNet,
  testutils/unittests,
  chronos,
  chronicles,
  libp2p/switch,
  libp2p/protocols/ping,
  libp2p/stream/bufferstream,
  libp2p/stream/connection,
  libp2p/crypto/crypto
import
  ../../waku/waku_core,
  ../../waku/waku_node,
  ./testlib/wakucore,
  ./testlib/wakunode


suite "Waku Keepalive":

  asyncTest "handle ping keepalives":
    let
      nodeKey1 = generateSecp256k1Key()
      node1 = newTestWakuNode(nodeKey1, ValidIpAddress.init("0.0.0.0"), Port(0))
      nodeKey2 = generateSecp256k1Key()
      node2 = newTestWakuNode(nodeKey2, ValidIpAddress.init("0.0.0.0"), Port(0))

    var completionFut = newFuture[bool]()

    proc pingHandler(peerId: PeerID) {.async, gcsafe.} =
      debug "Ping received"

      check:
        peerId == node1.switch.peerInfo.peerId

      completionFut.complete(true)

    await node1.start()
    await node1.mountRelay()
    await node1.mountLibp2pPing()

    await node2.start()
    await node2.mountRelay()

    let pingProto = Ping.new(handler = pingHandler)
    await pingProto.start()
    node2.switch.mount(pingProto)

    await node1.connectToNodes(@[node2.switch.peerInfo.toRemotePeerInfo()])

    node1.startKeepalive()

    check:
      (await completionFut.withTimeout(5.seconds)) == true

    await node2.stop()
    await node1.stop()
