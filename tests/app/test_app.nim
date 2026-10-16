{.used.}

import
  std/[json, net, sequtils, strutils],
  testutils/unittests,
  chronicles,
  chronos,
  libp2p/[crypto/crypto, crypto/secp, multiaddress, peerinfo, switch],
  libp2p/services/natservice,
  tests/testlib/[wakucore, wakunode],
  logos_delivery/waku/factory/conf_builder/conf_builder

include logos_delivery/waku/kernel, logos_delivery/waku/common/enr/typed_record

suite "Node app - Waku":
  test "compilation version should be reported":
    ## Given
    let conf = defaultTestWakuConf()

    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    ## When
    let version = kernel.getNodeInfoItem(NodeInfoId.Version)

    ## Then
    check:
      version == git_version

  test "max message size should be reported from node info":
    ## Given
    let conf = defaultTestWakuConf()

    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    ## When
    let maxMessageSize = kernel.getNodeInfoItem(NodeInfoId.MaxMessageSize)

    ## Then
    check:
      maxMessageSize == $conf.maxMessageSizeBytes

  test "is running should follow start and stop":
    ## Given
    let conf = defaultTestWakuConf()

    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    ## When
    let beforeStart = kernel.getNodeInfoItem(NodeInfoId.IsRunning)
    (waitFor kernel.start()).isOkOr:
      raiseAssert error
    let afterStart = kernel.getNodeInfoItem(NodeInfoId.IsRunning)
    (waitFor kernel.stop()).isOkOr:
      raiseAssert error
    let afterStop = kernel.getNodeInfoItem(NodeInfoId.IsRunning)

    ## Then
    check:
      beforeStart == "false"
      afterStart == "true"
      afterStop == "false"

suite "Node app - Waku initialization":
  test "peer persistence setup should be successfully mounted":
    ## Given
    var conf = defaultTestWakuConf()
    conf.peerPersistence = true

    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    check:
      not kernel.peerManager.storage.isNil()

  test "node setup is successful with default configuration":
    ## Given
    var conf = defaultTestWakuConf()

    ## When
    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    ## Then
    let node = kernel
    check:
      not node.isNil()
      node.protocols.archive.isNil()
      node.protocols.store.isNil()
      not node.protocols.storeClient.isNil()
      not node.discovery.rendezvous.isNil()

    ## Cleanup
    (waitFor kernel.stop()).isOkOr:
      raiseAssert error

  test "production service composition carries NATService":
    ## The test runs the full path from conf to switch services.
    ## The autonat append must keep NATService in switch.services.
    var conf = defaultTestWakuConf()
    conf.endpointConf.natStrategy = parseNatStrategy("upnp").expect("upnp")
    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    let services = kernel.switch.services
    check:
      services.filterIt(it of NATService).len == 1

  test "ext-multiaddr-only leaves automatic NAT port mapping off":
    ## libp2p runs the mappers even with an explicit list, so the factory configures none.
    var conf = defaultTestWakuConf()
    conf.endpointConf.extMultiAddrs =
      @[MultiAddress.init("/ip4/203.0.113.44/tcp/60123").get()]
    conf.endpointConf.extMultiAddrsOnly = true
    conf.endpointConf.natStrategy = parseNatStrategy("upnp").expect("upnp")
    let kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    check kernel.switch.services.filterIt(it of NATService).len == 0

  test "a post-start commit reaches the ENR through the production hook":
    ## Deleting the onCommittedAddresses callback fails this.
    ## So does setting it after the first refresh.
    var conf = defaultTestWakuConf()
    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    let extra = MultiAddress.init("/ip4/203.0.113.55/tcp/60555").get()
    kernel.switch.peerInfo.addressMappers.add(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        return addrs & @[extra]
    )
    let fieldBefore = kernel.enr.tryGet(MultiaddrEnrField, seq[byte])
    waitFor kernel.switch.peerInfo.update()

    let fieldAfter = kernel.enr.tryGet(MultiaddrEnrField, seq[byte])
    check:
      extra in kernel.announcedAddresses
      fieldAfter.isSome()
      fieldAfter != fieldBefore

    (waitFor kernel.stop()).isOkOr:
      raiseAssert error

  test "app properly handles dynamic port configuration":
    ## Given
    var conf = defaultTestWakuConf()
    conf.endpointConf.p2pTcpPort = Port(0)

    ## When
    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error

    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    ## Then
    let
      node = kernel
      typedNodeEnr = node.enr.toTyped()

    assert typedNodeEnr.isOk(), $typedNodeEnr.error
    let tcpPort = typedNodeEnr.value.tcp()
    assert tcpPort.isSome()
    check tcpPort.get() != 0

    check:
      # Waku started properly
      not node.isNil()
      node.protocols.archive.isNil()
      node.protocols.store.isNil()
      not node.protocols.storeClient.isNil()
      not node.discovery.rendezvous.isNil()

      # DS structures are updated with dynamic ports
      typedNodeEnr.get().tcp.get() != 0

    ## Cleanup
    (waitFor kernel.stop()).isOkOr:
      raiseAssert error

  test "explicit port=0 triggers auto-bind across all services":
    var builder = defaultTestWakuConfBuilder()
    builder.withP2pTcpPort(Port(0))
    builder.discv5Conf.withEnabled(true)
    builder.discv5Conf.withUdpPort(Port(0))
    builder.metricsServerConf.withEnabled(true)
    builder.metricsServerConf.withHttpPort(Port(0))
    builder.webSocketConf.withEnabled(true)
    builder.webSocketConf.withWebSocketPort(Port(0))

    let conf = builder.build().valueOr:
      raiseAssert error

    check:
      conf.endpointConf.p2pTcpPort == Port(0)
      conf.discv5Conf.get().udpPort == Port(0)
      conf.metricsServerConf.get().httpPort == Port(0)
      conf.webSocketConf.get().port == Port(0)

    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor kernel.stop()).isOkOr:
        raiseAssert error

    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    let portsJson = kernel.getNodeInfoItem(NodeInfoId.MyBoundPorts)
    let parsed = parseJson(portsJson)

    check:
      parsed.kind == JObject
      parsed["tcp"].getInt() != 0
      parsed["webSocket"].getInt() != 0
      parsed["discv5Udp"].getInt() != 0
      parsed["metrics"].getInt() != 0

  test "QUIC port=0 auto-binds and advertises the real port":
    var builder = defaultTestWakuConfBuilder()
    builder.withP2pListenAddress(parseIpAddress("127.0.0.1"))
    builder.withP2pTcpPort(Port(0))
    builder.quicConf.withEnabled(true)
    builder.quicConf.withQuicPort(Port(0))

    let conf = builder.build().valueOr:
      raiseAssert error
    check conf.quicConf.get().port == Port(0)

    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor kernel.stop()).isOkOr:
        raiseAssert error

    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    let parsed = parseJson(kernel.getNodeInfoItem(NodeInfoId.MyBoundPorts))
    check parsed["quic"].getInt() != 0

    let quicAddrs = kernel.announcedAddresses.filterIt("/quic-v1" in $it)
    check:
      quicAddrs.len >= 1
      quicAddrs.allIt("/udp/0/quic-v1" notin $it)

  test "portsShift is applied exactly once":
    # The announced port must equal the bound port, not bound + portsShift.
    const shift = 5'u16

    # Reserve a free port, then set base = port - shift so base + shift binds onto it.
    let boundTarget = block:
      let sock = newSocket()
      defer:
        sock.close()
      sock.bindAddr(Port(0), "127.0.0.1")
      sock.getLocalAddr()[1]
    doAssert boundTarget.uint16 > shift, "ephemeral port unexpectedly low"

    var builder = defaultTestWakuConfBuilder()
    builder.withP2pListenAddress(parseIpAddress("127.0.0.1"))
    builder.withP2pTcpPort(Port(boundTarget.uint16 - shift))
    builder.withPortsShift(shift)

    let conf = builder.build().valueOr:
      raiseAssert error

    var kernel = (waitFor Kernel.new(conf)).valueOr:
      raiseAssert error
    defer:
      (waitFor kernel.stop()).isOkOr:
        raiseAssert error

    (waitFor kernel.start()).isOkOr:
      raiseAssert error

    let typedEnr = kernel.enr.toTyped().valueOr:
      raiseAssert $error
    let announcedTcp = typedEnr.tcp()

    check:
      announcedTcp.isSome()
      kernel.ports.tcp == boundTarget.uint16
      announcedTcp.get() == kernel.ports.tcp
