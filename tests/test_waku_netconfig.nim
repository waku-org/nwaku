{.used.}

import chronos, confutils/toml/std/net, libp2p/multiaddress, testutils/unittests

import ./testlib/wakunode, waku_enr/capabilities

include node/config

proc defaultTestWakuFlags(): CapabilitiesBitfield =
  CapabilitiesBitfield.init(
    lightpush = false, filter = false, store = false, relay = true
  )

suite "Waku NetConfig":
  asyncTest "Create NetConfig with default values":
    let conf = defaultTestWakuNodeConf()

    let wakuFlags = defaultTestWakuFlags()

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extIp = none(IpAddress),
      extPort = none(Port),
      extMultiAddrs = @[],
      wsBindPort = conf.websocketPort,
      wsEnabled = conf.websocketSupport,
      wssEnabled = conf.websocketSecureSupport,
      dns4DomainName = none(string),
      discv5UdpPort = none(Port),
      wakuFlags = some(wakuFlags),
    )

    check:
      netConfigRes.isOk()

  asyncTest "AnnouncedAddresses contains only bind address when no external addresses are provided":
    let conf = defaultTestWakuNodeConf()

    let netConfigRes =
      NetConfig.init(bindIp = conf.listenAddress, bindPort = conf.tcpPort)

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only bind address should be present
      netConfig.announcedAddresses[0] ==
        formatListenAddress(ip4TcpEndPoint(conf.listenAddress, conf.tcpPort))

  asyncTest "AnnouncedAddresses contains external address if extIp/Port are provided":
    let
      conf = defaultTestWakuNodeConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only external address should be present
      netConfig.announcedAddresses[0] == ip4TcpEndPoint(extIp, extPort)

  asyncTest "AnnouncedAddresses contains dns4DomainName if provided":
    let
      conf = defaultTestWakuNodeConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # Only DNS address should be present
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)

  asyncTest "AnnouncedAddresses includes extMultiAddrs when provided":
    let
      conf = defaultTestWakuNodeConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      extMultiAddrs = @[ip4TcpEndPoint(extIp, extPort)]

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extMultiAddrs = extMultiAddrs,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

  asyncTest "AnnouncedAddresses uses dns4DomainName over extIp when both are provided":
    let
      conf = defaultTestWakuNodeConf()
      dns4DomainName = "example.com"
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      dns4DomainName = some(dns4DomainName),
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # DNS address
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)

  asyncTest "AnnouncedAddresses includes WebSocket addresses when enabled":
    var
      conf = defaultTestWakuNodeConf()
      wssEnabled = false

    var netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    var netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] ==
        (ip4TcpEndPoint(conf.listenAddress, conf.websocketPort) & wsFlag(wssEnabled))

    ## Now try the same for the case of wssEnabled = true

    wssEnabled = true

    netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] ==
        (ip4TcpEndPoint(conf.listenAddress, conf.websocketPort) & wsFlag(wssEnabled))

  asyncTest "Announced WebSocket address contains external IP if provided":
    let
      conf = defaultTestWakuNodeConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # External address + wsHostAddress
      netConfig.announcedAddresses[1] ==
        (ip4TcpEndPoint(extIp, conf.websocketPort) & wsFlag(wssEnabled))

  asyncTest "Announced WebSocket address contains dns4DomainName if provided":
    let
      conf = defaultTestWakuNodeConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + wsHostAddress
      netConfig.announcedAddresses[1] ==
        (dns4TcpEndPoint(dns4DomainName, conf.websocketPort) & wsFlag(wssEnabled))

  asyncTest "Announced WebSocket address contains dns4DomainName if provided alongside extIp":
    let
      conf = defaultTestWakuNodeConf()
      dns4DomainName = "example.com"
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)
      wssEnabled = false

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      dns4DomainName = some(dns4DomainName),
      extIp = some(extIp),
      extPort = some(extPort),
      wsEnabled = true,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # DNS address + wsHostAddress
      netConfig.announcedAddresses[0] == dns4TcpEndPoint(dns4DomainName, extPort)
      netConfig.announcedAddresses[1] ==
        (dns4TcpEndPoint(dns4DomainName, conf.websocketPort) & wsFlag(wssEnabled))

  asyncTest "ENR is set with bindIp/Port if no extIp/Port are provided":
    let conf = defaultTestWakuNodeConf()

    let netConfigRes =
      NetConfig.init(bindIp = conf.listenAddress, bindPort = conf.tcpPort)

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.enrIp.get() == conf.listenAddress
      netConfig.enrPort.get() == conf.tcpPort

  asyncTest "ENR is set with extIp/Port if provided":
    let
      conf = defaultTestWakuNodeConf()
      extIp = parseIpAddress("1.2.3.4")
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extIp = some(extIp),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.extIp.get() == extIp
      netConfig.enrPort.get() == extPort

  asyncTest "ENR is set with dns4DomainName if provided":
    let
      conf = defaultTestWakuNodeConf()
      dns4DomainName = "example.com"
      extPort = Port(1234)

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      dns4DomainName = some(dns4DomainName),
      extPort = some(extPort),
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.enrMultiaddrs.contains(dns4TcpEndPoint(dns4DomainName, extPort))

  asyncTest "wsHostAddress is not announced if a WS/WSS address is provided in extMultiAddrs":
    var
      conf = defaultTestWakuNodeConf()
      extAddIp = parseIpAddress("1.2.3.4")
      extAddPort = Port(1234)
      wsEnabled = true
      wssEnabled = false
      extMultiAddrs = @[(ip4TcpEndPoint(extAddIp, extAddPort) & wsFlag(wssEnabled))]

    var netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extMultiAddrs = extMultiAddrs,
      wsEnabled = wsEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    var netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

    # Now same test for WSS external address
    wssEnabled = true
    extMultiAddrs = @[(ip4TcpEndPoint(extAddIp, extAddPort) & wsFlag(wssEnabled))]

    netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extMultiAddrs = extMultiAddrs,
      wssEnabled = wssEnabled,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 2 # Bind address + extAddress
      netConfig.announcedAddresses[1] == extMultiAddrs[0]

  asyncTest "Only extMultiAddrs are published when enabling extMultiAddrsOnly flag":
    let
      conf = defaultTestWakuNodeConf()
      extAddIp = parseIpAddress("1.2.3.4")
      extAddPort = Port(1234)
      extMultiAddrs = @[ip4TcpEndPoint(extAddIp, extAddPort)]

    let netConfigRes = NetConfig.init(
      bindIp = conf.listenAddress,
      bindPort = conf.tcpPort,
      extMultiAddrs = extMultiAddrs,
      extMultiAddrsOnly = true,
    )

    assert netConfigRes.isOk(), $netConfigRes.error

    let netConfig = netConfigRes.get()

    check:
      netConfig.announcedAddresses.len == 1 # ExtAddress
      netConfig.announcedAddresses[0] == extMultiAddrs[0]
