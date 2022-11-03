{.used.}

import
  std/[options, tables, sets],
  testutils/unittests,
  chronos,
  chronicles,
  stew/shims/net,
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/multistream,
  eth/keys,
  eth/p2p/discoveryv5/enr
import
  ../../waku/v2/node/waku_node,
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/node/discv5/waku_discv5,
  ../../waku/v2/protocol/waku_peer_exchange,
  ../../waku/v2/protocol/waku_relay,
  ../test_helpers,
  ./utils


# TODO: Extend test coverage
procSuite "Waku Peer Exchange":

  asyncTest "encode and decode peer exchange response":
    ## Setup
    var
      enr1 = enr.Record(seqNum: 0, raw: @[])
      enr2 = enr.Record(seqNum: 0, raw: @[])

    discard enr1.fromUri("enr:-JK4QPmO-sE2ELiWr8qVFs1kaY4jQZQpNaHvSPRmKiKcaDoqYRdki2c1BKSliImsxFeOD_UHnkddNL2l0XT9wlsP0WEBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQIMwKqlOl3zpwnrsKRKHuWPSuFzit1Cl6IZvL2uzBRe8oN0Y3CC6mKDdWRwgiMqhXdha3UyDw")
    discard enr2.fromUri("enr:-Iu4QK_T7kzAmewG92u1pr7o6St3sBqXaiIaWIsFNW53_maJEaOtGLSN2FUbm6LmVxSfb1WfC7Eyk-nFYI7Gs3SlchwBgmlkgnY0gmlwhI5d6VKJc2VjcDI1NmsxoQLPYQDvrrFdCrhqw3JuFaGD71I8PtPfk6e7TJ3pg_vFQYN0Y3CC6mKDdWRwgiMq")

    let peerInfos = @[
      PeerExchangePeerInfo(enr: enr1.raw),
      PeerExchangePeerInfo(enr: enr2.raw),
    ]

    var rpc = PeerExchangeRpc(
      response: PeerExchangeResponse(
        peerInfos: peerInfos
      )
    )

    ## When
    let
      rpcBuffer: seq[byte] = rpc.encode().buffer
      res = PeerExchangeRpc.init(rpcBuffer)

    ## Then
    check:
      res.isOk
      res.get().response.peerInfos == peerInfos

    ## When
    var
      resEnr1 = enr.Record(seqNum: 0, raw: @[])
      resEnr2 = enr.Record(seqNum: 0, raw: @[])

    discard resEnr1.fromBytes(res.get().response.peerInfos[0].enr)
    discard resEnr2.fromBytes(res.get().response.peerInfos[1].enr)

    ## Then
    check:
      resEnr1 == enr1
      resEnr2 == enr2

  asyncTest "retrieve and provide peer exchange peers from discv5":
    ## Setup (copied from test_waku_discv5.nim)
    let
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")

      nodeKey1 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort1 = Port(64010)
      nodeUdpPort1 = Port(9000)
      node1 = WakuNode.new(nodeKey1, bindIp, nodeTcpPort1)

      nodeKey2 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort2 = Port(64012)
      nodeUdpPort2 = Port(9002)
      node2 = WakuNode.new(nodeKey2, bindIp, nodeTcpPort2)

      nodeKey3 = crypto.PrivateKey.random(Secp256k1, rng[])[]
      nodeTcpPort3 = Port(64014)
      nodeUdpPort3 = Port(9004)
      node3 = WakuNode.new(nodeKey3, bindIp, nodeTcpPort3)

      # todo: px flag
      flags = initWakuFlags(lightpush = false,
                            filter = false,
                            store = false,
                            relay = true)

    # Mount discv5
    node1.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort1), some(nodeUdpPort1),
        bindIp,
        nodeUdpPort1,
        newSeq[string](),
        false,
        keys.PrivateKey(nodeKey1.skkey),
        flags,
        [], # Empty enr fields, for now
        node1.rng
      )

    node2.wakuDiscv5 = WakuDiscoveryV5.new(
        some(extIp), some(nodeTcpPort2), some(nodeUdpPort2),
        bindIp,
        nodeUdpPort2,
        @[node1.wakuDiscv5.protocol.localNode.record.toURI()], # Bootstrap with node1
        false,
        keys.PrivateKey(nodeKey2.skkey),
        flags,
        [], # Empty enr fields, for now
        node2.rng
      )

    ## Given
    await allFutures([node1.start(), node2.start(), node3.start()])
    await allFutures([node1.startDiscv5(), node2.startDiscv5()])

    # Mount peer exchange
    await node1.mountPeerExchange()
    await node3.mountPeerExchange()

    await sleepAsync(3000.millis) # Give the algorithm some time to work its magic

    asyncSpawn node1.wakuPeerExchange.runPeerExchangeDiscv5Loop()

    node3.setPeerExchangePeer(node1.peerInfo.toRemotePeerInfo())

    ## When
    discard waitFor node3.wakuPeerExchange.request(1)

    await sleepAsync(2000.millis) # Give the algorithm some time to work its magic

    ## Then
    check:
      node1.wakuDiscv5.protocol.nodesDiscovered > 0
      node3.switch.peerStore[AddressBook].contains(node2.switch.peerInfo.peerId)

    await allFutures([node1.stop(), node2.stop(), node3.stop()])
