{.used.}

## libp2p resolves peerInfo.addrs inside switch.start, before the mounted
## protocols start. These tests check that result and its copies (ENR, API).

import results
import std/[net, sequtils, strutils]
import testutils/unittests, chronos
import libp2p/[multiaddress, switch, wire]
import libp2p/crypto/crypto as libp2pcrypto
import libp2p/protocols/protocol
import libp2p/stream/connection
import libp2p/services/natservice
import chronos/transports/osnet
import libp2p/services/nat/portmapper
import eth/p2p/discoveryv5/protocol as discv5_protocol
import ../logos_delivery/kernel/discovery/waku_discv5
import eth/keys, eth/p2p/discoveryv5/enr
import stew/byteutils
import
  ../logos_delivery/kernel/net/net_config,
  ../logos_delivery/kernel/kernel,
  ../logos_delivery/kernel/kernel_lifecycle,
  logos_delivery/kernel/
    [common/enr/builder, common/enr/typed_record, enr/multiaddr, enr/sharding]
import ./testlib/[common, wakucore, wakunode]

const LoopbackIp = parseIpAddress("127.0.0.1")

const CircuitAddr =
  "/ip4/93.184.216.34/tcp/4001/p2p/" &
  "16Uiu2HAm7YEh2wwbYNvayrSQe2bdm1aL4FnhCLkvSNaScMxcgt4n/p2p-circuit"

type RecordingMapper = ref object of PortMapper
  grantIp: IpAddress
  grantPort: Port
  mappedInternal: seq[Port]

method map(
    self: RecordingMapper, internalPort: Port, externalPort: Port, proto: MapProto
): Future[Result[MappedPort, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.mappedInternal.add(internalPort)
  return ok(MappedPort(externalIp: self.grantIp, externalPort: self.grantPort))

method unmap(
    self: RecordingMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return ok()

method close(self: RecordingMapper) {.async: (raises: []), gcsafe.} =
  discard

type UpdateBeforeBind = ref object of Service
  ## Calls peerInfo.update() before the transports bind, as libp2p's AutonatService
  ## does in production. The base mapper must drop port-0 entries in that update.

method setup(self: UpdateBeforeBind, switch: Switch) {.raises: [ServiceSetupError].} =
  discard

method start(
    self: UpdateBeforeBind, switch: Switch
) {.async: (raises: [CancelledError]).} =
  await switch.peerInfo.update()

method stop(
    self: UpdateBeforeBind, switch: Switch
) {.async: (raises: [CancelledError]).} =
  discard

const PrivateInterfaceIp = static(parseIpAddress("192.168.9.9"))

proc privateInterfaceProvider(
    addrFamily: AddressFamily
): seq[InterfaceAddress] {.gcsafe, raises: [].} =
  ## A deterministic stand-in for the primary interface: a private IPv4.
  if addrFamily != AddressFamily.IPv4:
    return @[]
  @[InterfaceAddress.init(initTAddress(PrivateInterfaceIp, Port(0)), 24)]

type AddressProbe = ref object of LPProtocol
  ## Records peerInfo.addrs when the switch starts the mounted protocols.
  switch: Switch
  addrsAtStart: seq[MultiAddress]

method start(p: AddressProbe) {.async: (raises: [CancelledError]).} =
  p.addrsAtStart = p.switch.peerInfo.addrs
  p.started = true

procSuite "Announced addresses":
  asyncTest "the resolved base reaches peerInfo and the API projection":
    let kernel =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      kernel.announcedAddresses.len > 0
      kernel.announcedAddresses == kernel.switch.peerInfo.addrs
      kernel.announcedAddresses.allIt("/tcp/0" notin $it and "/udp/0/" notin $it)
      kernel.announcedAddresses.allIt("0.0.0.0" notin $it)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "a wildcard bind is resolved in peerInfo.addrs before the mounted protocols start":
    ## The helper rewrites 0.0.0.0 to loopback when quic is on, so quic is off.
    let kernel = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    let probe = AddressProbe(switch: kernel.switch)
    probe.codec = "/waku/test/address-probe/1.0.0"
    probe.handler = proc(
        stream: Stream, proto: string
    ) {.async: (raises: [CancelledError]).} =
      discard
    kernel.switch.mount(probe)

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      probe.addrsAtStart.len > 0
      probe.addrsAtStart.allIt("0.0.0.0" notin $it and "/tcp/0" notin $it)
      ## Nothing after switch.start changed peerInfo.addrs.
      probe.addrsAtStart == kernel.switch.peerInfo.addrs
      probe.addrsAtStart == kernel.announcedAddresses
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "a loopback bind stays loopback in the base":
    ## Rewriting loopback to the LAN IP once crashed the test suite
    ## because it announces endpoints nothing listens on.
    let kernel =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      kernel.announcedAddresses.len > 0
      kernel.announcedAddresses.allIt("/ip4/127.0.0.1/" in $it)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "an operator host containing the wildcard substring survives intact":
    ## The host string contains "0.0.0.0". Text replacement corrupted it.
    ## Matching the parsed IP keeps it unchanged.
    let tricky = MultiAddress.init("/ip4/10.0.0.0/tcp/60123").get()
    let kernel = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[tricky],
    )
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      tricky in kernel.announcedAddresses
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "the ipv4-mapped wildcard is rewritten like the plain one":
    ## `::ffff:0.0.0.0` is the wildcard host too, so it has to be replaced by
    ## the primary IP rather than dropped from what the node announces.
    let mapped = MultiAddress.init("/ip6/::ffff:0.0.0.0/tcp/60123").get()
    let kernel = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[mapped],
    )
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      kernel.announcedAddresses.allIt(not it.getIp().get(LoopbackIp).isWildcard())
      kernel.announcedAddresses.anyIt("/tcp/60123" in $it)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "a circuit route flows through the chain, and removal converges on the next update":
    let kernel =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error

    let circuit = MultiAddress.init(CircuitAddr).get()
    var injecting = true
    kernel.switch.peerInfo.addressMappers.add(
      proc(
          addrs: seq[MultiAddress]
      ): Future[seq[MultiAddress]] {.gcsafe, async: (raises: [CancelledError]).} =
        if injecting:
          return @[circuit] & addrs
        return addrs
    )

    ## The service's own update carries the route.
    await kernel.switch.peerInfo.update()
    check:
      circuit in kernel.switch.peerInfo.addrs
      circuit in kernel.announcedAddresses
      kernel.announcedAddresses.anyIt(not it.isCircuitRelayMA())

    ## libp2p keeps peerInfo unchanged on removal.
    ## The stale route stays until the next update.
    injecting = false
    check circuit in kernel.announcedAddresses ## stale until next update
    await kernel.switch.peerInfo.update() ## any later natural commit
    check:
      circuit notin kernel.switch.peerInfo.addrs
      circuit notin kernel.announcedAddresses
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "NAT restart derives from the configured intent":
    var recorders: seq[RecordingMapper]
    var grantPort = Port(62001)
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: grantPort)
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    ## A private configured address for NATService to map.
    ## The test runs the same on every machine.
    let kernel = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[MultiAddress.init("/ip4/192.168.77.7/tcp/60111").get()],
    )
    let natSvc = NATService.new(upnpConfig(), rng(), portMapperFactory = factory)
    ## NAT first, then the update, as in Kernel.new.
    kernel.switch.services.add(Service(natSvc))
    kernel.switch.services.add(Service(UpdateBeforeBind()))

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    let mappersAfterFirstStart = kernel.switch.peerInfo.addressMappers.len
    check kernel.announcedAddresses.anyIt("203.0.113.77" in $it and "62001" in $it)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

    grantPort = Port(62002)
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      ## The mapper count stays flat across restarts.
      kernel.switch.peerInfo.addressMappers.len == mappersAfterFirstStart
      ## The new grant is announced. The mapper got the configured address.
      kernel.announcedAddresses.anyIt("203.0.113.77" in $it and "62002" in $it)
      recorders.allIt(Port(0) notin it.mappedInternal)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "NAT maps the port a wildcard bind actually bound":
    ## The wildcard bind resolves onto the provider's interface before the NAT
    ## mapper runs, so NAT maps the bound port and the granted address is announced.
    var recorders: seq[RecordingMapper]
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: Port(62010))
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    ## The helper rewrites 0.0.0.0 to loopback when quic is on, so quic is off.
    let kernel = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    kernel.switch.addressManager.networkInterfaceProvider = privateInterfaceProvider
    kernel.switch.services.add(
      Service(NATService.new(upnpConfig(), rng(), portMapperFactory = factory))
    )

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    let bound = kernel.boundTcpPort()
    check:
      bound != Port(0)
      recorders.len >= 1
      recorders.allIt(it.mappedInternal.len >= 1)
      recorders.allIt(it.mappedInternal.allIt(it == bound))
      kernel.announcedAddresses.anyIt("203.0.113.77" in $it and "62010" in $it)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "a fixed port is mapped in both mapper runs and announced once":
    ## Production binds a fixed port and AutonatService updates peerInfo during the
    ## bind, so the mappers run twice. Both runs map the configured port, never 0.
    var recorders: seq[RecordingMapper]
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: Port(62020))
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    const FixedPort = Port(61020)
    let kernel = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), FixedPort, quicEnabled = false
    )
    kernel.switch.addressManager.networkInterfaceProvider = privateInterfaceProvider
    kernel.switch.services.add(
      Service(NATService.new(upnpConfig(), rng(), portMapperFactory = factory))
    )
    kernel.switch.services.add(Service(UpdateBeforeBind()))

    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      recorders.len >= 1
      recorders.allIt(it.mappedInternal == @[FixedPort, FixedPort])
      kernel.announcedAddresses.filterIt("203.0.113.77" in $it and "62020" in $it).len ==
        1
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "a later update announces the current primary interface":
    ## The provider runs on every update, so a changed primary IP replaces the old one.
    var primary = parseIpAddress("192.168.9.9")
    let movingProvider = proc(
        addrFamily: AddressFamily
    ): seq[InterfaceAddress] {.gcsafe, raises: [].} =
      if addrFamily != AddressFamily.IPv4:
        return @[]
      {.gcsafe.}:
        @[InterfaceAddress.init(initTAddress(primary, Port(0)), 24)]

    let kernel = newTestWakuNode(
      generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0), quicEnabled = false
    )
    kernel.switch.addressManager.networkInterfaceProvider = movingProvider
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    let bound = kernel.boundTcpPort()
    check kernel.announcedAddresses ==
      @[MultiAddress.init("/ip4/192.168.9.9/tcp/" & $bound).get()]

    primary = parseIpAddress("192.168.9.10")
    await kernel.switch.peerInfo.update()
    check kernel.announcedAddresses ==
      @[MultiAddress.init("/ip4/192.168.9.10/tcp/" & $bound).get()]
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "an unchanged owned update needs the explicit copy":
    let kernel =
      newTestWakuNode(generateSecp256k1Key(), parseIpAddress("127.0.0.1"), Port(0))
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    let committed = kernel.switch.peerInfo.addrs

    kernel.announcedAddresses = @[]
    await kernel.switch.peerInfo.update()
    check kernel.announcedAddresses.len == 0 ## unchanged commit, observer silent

    kernel.copyCommittedAddresses()
    check kernel.announcedAddresses == committed
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  asyncTest "ext-multiaddr-only bypasses the chain from before start":
    let ext = MultiAddress.init("/ip4/203.0.113.44/tcp/60123").get()
    var recorders: seq[RecordingMapper]
    let grantIp = parseIpAddress("203.0.113.77")
    let factory = proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].} =
      let rec = RecordingMapper(grantIp: grantIp, grantPort: Port(62003))
      {.gcsafe.}:
        recorders.add(rec)
      Opt.some(PortMapper(rec))

    let kernel = newTestWakuNode(
      generateSecp256k1Key(),
      parseIpAddress("127.0.0.1"),
      Port(0),
      extMultiAddrs = @[ext],
      extMultiAddrsOnly = true,
    )
    ## The override is active from construction, before any start.
    check kernel.switch.peerInfo.announcedAddrs == @[ext]

    kernel.switch.services.add(Service(UpdateBeforeBind()))
    kernel.switch.services.add(
      Service(NATService.new(upnpConfig(), rng(), portMapperFactory = factory))
    )
    (await kernel.start()).isOkOr:
      raiseAssert "failed to start kernel: " & error
    check:
      kernel.announcedAddresses == @[ext]
      kernel.switch.peerInfo.addrs == @[ext]
      ## The mappers ran over the configured list, which has nothing private to map.
      ## libp2p announced that list itself. Every mapper stayed idle.
      recorders.len >= 1
      recorders.allIt(it.mappedInternal.len == 0)
    (await kernel.stop()).isOkOr:
      raiseAssert "failed to stop kernel: " & error

  test "the ENR refresh trims to the largest fitting prefix and keeps shards":
    let key = generateSecp256k1Key()
    let kernel = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))
    var builder = EnrBuilder.init(key)
    builder
      .withWakuRelaySharding(RelayShards(clusterId: 1, shardIds: @[0'u16, 1, 2, 3]))
      .expect("shards")
    kernel.enr = builder.build().expect("record")

    var addrs: seq[MultiAddress]
    for i in 0 ..< 6:
      addrs.add(MultiAddress.init(CircuitAddr).get())
      addrs.add(MultiAddress.init("/ip4/203.0.113." & $i & "/tcp/60000").get())
    kernel.announcedAddresses = addrs

    check refreshEnrAddrs(kernel, key, nil).isOk()

    let typed = kernel.enr.toTyped().expect("typed")
    let decoded = typed.multiaddrs.expect("multiaddrs field")
    check:
      decoded.len > 0
      decoded.len < addrs.len ## oversized input was trimmed
      decoded[0].isCircuitRelayMA() ## relay routes sort first and stay
      kernel.enr.toTyped().expect("typed").relaySharding().isSome()

  test "an empty committed set clears the ENR multiaddrs field":
    let key = generateSecp256k1Key()
    let kernel = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))
    kernel.announcedAddresses = @[MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get()]
    check refreshEnrAddrs(kernel, key, nil).isOk()
    kernel.announcedAddresses = @[]
    check refreshEnrAddrs(kernel, key, nil).isOk()
    let typed = kernel.enr.toTyped().expect("typed")
    check typed.multiaddrs.expect("field").len == 0

  test "the live discv5 record takes the refresh and copies back":
    let key = generateSecp256k1Key()
    let kernel = newTestWakuNode(key, parseIpAddress("127.0.0.1"), Port(0))

    var builder = EnrBuilder.init(key)
    builder
      .withWakuRelaySharding(RelayShards(clusterId: 1, shardIds: @[0'u16, 5]))
      .expect("shards")
    let seedRecord = builder.build().expect("record")

    let keyBytes = key.getRawBytes().expect("raw")
    let ethPk = keys.PrivateKey.fromHex(byteutils.toHex(keyBytes)).expect("pk")
    let proto = discv5_protocol.newProtocol(
      ethPk,
      enrIp = Opt.none(IpAddress),
      enrTcpPort = Opt.none(Port),
      enrUdpPort = Opt.none(Port),
      previousRecord = Opt.some(seedRecord),
      bindPort = Port(9909),
      bindIp = Opt.none(IpAddress),
    )
    let wd = WakuDiscoveryV5(protocol: proto)
    let seqBefore = proto.localNode.record.seqNum

    kernel.announcedAddresses = @[
      MultiAddress.init(CircuitAddr).get(),
      MultiAddress.init("/ip4/203.0.113.9/tcp/60000").get(),
    ]
    check refreshEnrAddrs(kernel, key, wd).isOk()

    let live = proto.localNode.record
    let typed = live.toTyped().expect("typed")
    check:
      typed.multiaddrs.expect("field").len == 2
      typed.relaySharding().isSome() ## shards stay after the field update
      live.seqNum > seqBefore
      kernel.enr == live ## copy-back
