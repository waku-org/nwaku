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
  ../../waku/v2/waku_node,
  ../../waku/v2/node/peer_manager,
  ../../waku/v2/waku_discv5,
  ../../waku/v2/waku_peer_exchange,
  ../../waku/v2/waku_peer_exchange/rpc,
  ../../waku/v2/waku_peer_exchange/rpc_codec,
  ../../waku/v2/waku_peer_exchange/protocol,
  ./testlib/wakucore,
  ./testlib/wakunode


# TODO: Extend test coverage
procSuite "Waku Peer Exchange":

  asyncTest "encode and decode peer exchange response":
    ## Setup
    var
      enr1 = enr.Record(seqNum: 0, raw: @[])
      enr2 = enr.Record(seqNum: 0, raw: @[])

    check enr1.fromUri("enr:-JK4QPmO-sE2ELiWr8qVFs1kaY4jQZQpNaHvSPRmKiKcaDoqYRdki2c1BKSliImsxFeOD_UHnkddNL2l0XT9wlsP0WEBgmlkgnY0gmlwhH8AAAGJc2VjcDI1NmsxoQIMwKqlOl3zpwnrsKRKHuWPSuFzit1Cl6IZvL2uzBRe8oN0Y3CC6mKDdWRwgiMqhXdha3UyDw")
    check enr2.fromUri("enr:-Iu4QK_T7kzAmewG92u1pr7o6St3sBqXaiIaWIsFNW53_maJEaOtGLSN2FUbm6LmVxSfb1WfC7Eyk-nFYI7Gs3SlchwBgmlkgnY0gmlwhI5d6VKJc2VjcDI1NmsxoQLPYQDvrrFdCrhqw3JuFaGD71I8PtPfk6e7TJ3pg_vFQYN0Y3CC6mKDdWRwgiMq")

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
      res = PeerExchangeRpc.decode(rpcBuffer)

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
    ## Given (copied from test_waku_discv5.nim)
    let
      # todo: px flag
      flags = CapabilitiesBitfield.init(
                lightpush = false,
                filter = false,
                store = false,
                relay = true
      )
      bindIp = ValidIpAddress.init("0.0.0.0")
      extIp = ValidIpAddress.init("127.0.0.1")

      nodeKey1 = generateSecp256k1Key()
      nodeTcpPort1 = Port(64010)
      nodeUdpPort1 = Port(9000)
      node1 = newTestWakuNode(
        nodeKey1,
        bindIp,
        nodeTcpPort1,
        some(extIp),
        wakuFlags = some(flags),
        discv5UdpPort = some(nodeUdpPort1)
      )

      nodeKey2 = generateSecp256k1Key()
      nodeTcpPort2 = Port(64012)
      nodeUdpPort2 = Port(9002)
      node2 = newTestWakuNode(nodeKey2,
        bindIp,
        nodeTcpPort2,
        some(extIp),
        wakuFlags = some(flags),
        discv5UdpPort = some(nodeUdpPort2)
      )

      nodeKey3 = generateSecp256k1Key()
      nodeTcpPort3 = Port(64014)
      nodeUdpPort3 = Port(9004)
      node3 = newTestWakuNode(nodeKey3,
        bindIp,
        nodeTcpPort3,
        some(extIp),
        wakuFlags = some(flags),
        discv5UdpPort = some(nodeUdpPort3)
      )

    # discv5
    let conf1 = WakuDiscoveryV5Config(
      discv5Config: none(DiscoveryConfig),
      address: bindIp,
      port: nodeUdpPort1,
      privateKey: keys.PrivateKey(nodeKey1.skkey),
      bootstrapRecords: @[],
      autoupdateRecord: true
    )

    let disc1 = WakuDiscoveryV5.new(
        node1.rng,
        conf1,
        some(node1.enr)
      )

    let conf2 = WakuDiscoveryV5Config(
      discv5Config: none(DiscoveryConfig),
      address: bindIp,
      port: nodeUdpPort2,
      privateKey: keys.PrivateKey(nodeKey2.skkey),
      bootstrapRecords: @[disc1.protocol.getRecord()],
      autoupdateRecord: true
    )

    let disc2 = WakuDiscoveryV5.new(
        node2.rng,
        conf2,
        some(node2.enr)
      )


    await allFutures(node1.start(), node2.start(), node3.start())
    await allFutures(disc1.start(), disc2.start())
    asyncSpawn disc1.searchLoop(node1.peerManager, none(enr.Record))
    asyncSpawn disc2.searchLoop(node2.peerManager, none(enr.Record))

    ## When
    var attempts = 10
    while (disc1.protocol.nodesDiscovered < 1 or
          disc2.protocol.nodesDiscovered < 1) and
          attempts > 0:
      await sleepAsync(1.seconds)
      attempts -= 1

    # node2 can be connected, so will be returned by peer exchange
    require (await node1.peerManager.connectRelay(node2.switch.peerInfo.toRemotePeerInfo()))

    # Mount peer exchange
    await node1.mountPeerExchange()
    await node3.mountPeerExchange()

    var peerInfosLen = 0
    var response: WakuPeerExchangeResult[PeerExchangeResponse]
    attempts = 10
    while peerInfosLen == 0 and attempts > 0:
      var connOpt = await node3.peerManager.dialPeer(node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec)
      require connOpt.isSome
      response = await node3.wakuPeerExchange.request(1, connOpt.get())
      require response.isOk
      peerInfosLen = response.get().peerInfos.len
      await sleepAsync(1.seconds)
      attempts -= 1

    ## Then
    check:
      response.get().peerInfos.len == 1
      response.get().peerInfos[0].enr == disc2.protocol.localNode.record.raw

    await allFutures([node1.stop(), node2.stop(), node3.stop(), disc1.stop(), disc2.stop()])

  asyncTest "peer exchange request functions returns some discovered peers":
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    # Start and mount peer exchange
    await allFutures([node1.start(), node2.start()])
    await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec)
    require:
      connOpt.isSome

    # Create some enr and add to peer exchange (sumilating disv5)
    var enr1, enr2 = enr.Record()
    check enr1.fromUri("enr:-Iu4QGNuTvNRulF3A4Kb9YHiIXLr0z_CpvWkWjWKU-o95zUPR_In02AWek4nsSk7G_-YDcaT4bDRPzt5JIWvFqkXSNcBgmlkgnY0gmlwhE0WsGeJc2VjcDI1NmsxoQKp9VzU2FAh7fwOwSpg1M_Ekz4zzl0Fpbg6po2ZwgVwQYN0Y3CC6mCFd2FrdTIB")
    check enr2.fromUri("enr:-Iu4QGJllOWlviPIh_SGR-VVm55nhnBIU5L-s3ran7ARz_4oDdtJPtUs3Bc5aqZHCiPQX6qzNYF2ARHER0JPX97TFbEBgmlkgnY0gmlwhE0WsGeJc2VjcDI1NmsxoQP3ULycvday4EkvtVu0VqbBdmOkbfVLJx8fPe0lE_dRkIN0Y3CC6mCFd2FrdTIB")

    # Mock that we have discovered these enrs
    node1.wakuPeerExchange.enrCache.add(enr1)
    node1.wakuPeerExchange.enrCache.add(enr2)

    # Request 2 peer from px. Test all request variants
    let response1 = await node2.wakuPeerExchange.request(2)
    let response2 = await node2.wakuPeerExchange.request(2, node1.peerInfo.toRemotePeerInfo())
    let response3 = await node2.wakuPeerExchange.request(2, connOpt.get())

    # Check the response or dont even continue
    require:
      response1.isOk
      response2.isOk
      response3.isOk

    check:
      response1.get().peerInfos.len == 2
      response2.get().peerInfos.len == 2
      response3.get().peerInfos.len == 2

      # Since it can return duplicates test that at least one of the enrs is in the response
      response1.get().peerInfos.anyIt(it.enr == enr1.raw) or response1.get().peerInfos.anyIt(it.enr == enr2.raw)
      response2.get().peerInfos.anyIt(it.enr == enr1.raw) or response2.get().peerInfos.anyIt(it.enr == enr2.raw)
      response3.get().peerInfos.anyIt(it.enr == enr1.raw) or response3.get().peerInfos.anyIt(it.enr == enr2.raw)

  asyncTest "peer exchange handler works as expected":
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    # Start and mount peer exchange
    await allFutures([node1.start(), node2.start()])
    await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

    # Mock that we have discovered these enrs
    var enr1 = enr.Record()
    check enr1.fromUri("enr:-Iu4QGNuTvNRulF3A4Kb9YHiIXLr0z_CpvWkWjWKU-o95zUPR_In02AWek4nsSk7G_-YDcaT4bDRPzt5JIWvFqkXSNcBgmlkgnY0gmlwhE0WsGeJc2VjcDI1NmsxoQKp9VzU2FAh7fwOwSpg1M_Ekz4zzl0Fpbg6po2ZwgVwQYN0Y3CC6mCFd2FrdTIB")
    node1.wakuPeerExchange.enrCache.add(enr1)

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec)
    require connOpt.isSome
    let conn = connOpt.get()

    # Send bytes so that they directly hit the handler
    let rpc = PeerExchangeRpc(
      request: PeerExchangeRequest(numPeers: 1))

    var buffer: seq[byte]
    await conn.writeLP(rpc.encode().buffer)
    buffer = await conn.readLp(MaxRpcSize.int)

    # Decode the response
    let decodedBuff = PeerExchangeRpc.decode(buffer)
    require decodedBuff.isOk

    # Check we got back the enr we mocked
    check:
      decodedBuff.get().response.peerInfos.len == 1
      decodedBuff.get().response.peerInfos[0].enr == enr1.raw

  asyncTest "peer exchange request fails gracefully":
    let
      node1 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))
      node2 = newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0))

    # Start and mount peer exchange
    await allFutures([node1.start(), node2.start()])
    await allFutures([node1.mountPeerExchange(), node2.mountPeerExchange()])

    # Create connection
    let connOpt = await node2.peerManager.dialPeer(node1.switch.peerInfo.toRemotePeerInfo(), WakuPeerExchangeCodec)
    require connOpt.isSome

    # Force closing the connection to simulate a failed peer
    await connOpt.get().close()

    # Request 2 peer from px
    let response = await node1.wakuPeerExchange.request(2, connOpt.get())

    # Check that it failed gracefully
    check: response.isErr


  asyncTest "connections are closed after response is sent":
    # Create 3 nodes
    let nodes = toSeq(0..<3).mapIt(newTestWakuNode(generateSecp256k1Key(), ValidIpAddress.init("0.0.0.0"), Port(0)))

    await allFutures(nodes.mapIt(it.start()))
    await allFutures(nodes.mapIt(it.mountPeerExchange()))

    # Multiple nodes request to node 0
    for i in 1..<3:
      let resp = await nodes[i].wakuPeerExchange.request(2, nodes[0].switch.peerInfo.toRemotePeerInfo())
      require resp.isOk

    # Wait for streams to be closed
    await sleepAsync(1.seconds)

    # Check that all streams are closed for px
    check:
      nodes[0].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)
      nodes[1].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)
      nodes[2].peerManager.getNumStreams(WakuPeerExchangeCodec) == (0, 0)
