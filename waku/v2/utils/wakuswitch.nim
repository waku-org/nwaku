# Waku Switch utils.
import
  std/[options, sequtils],
  chronos, chronicles,
  stew/byteutils,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/dnsresolver,
  libp2p/nameresolving/nameresolver,
  libp2p/builders,
  libp2p/transports/[transport, tcptransport, wstransport]

proc withWsTransport*(b: SwitchBuilder): SwitchBuilder =
  b.withTransport(proc(upgr: Upgrade): Transport = WsTransport.new(upgr))

proc newWakuSwitch*(
    privKey = none(crypto.PrivateKey),
    address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    wsAddress = MultiAddress.init("/ip4/127.0.0.1/tcp/1").tryGet(),
    secureManagers: openarray[SecureProtocol] = [
        SecureProtocol.Noise,
      ],
    transportFlags: set[ServerFlags] = {},
    rng = crypto.newRng(),
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    maxConnections = MaxConnections,
    maxIn = -1,
    maxOut = -1,
    maxConnsPerPeer = MaxConnectionsPerPeer,
    nameResolver: NameResolver = nil,
    wsEnabled: bool = false): Switch
    {.raises: [Defect, LPError].} =

    var b = SwitchBuilder
      .new()
      .withRng(rng)
      .withMaxConnections(maxConnections)
      .withMaxIn(maxIn)
      .withMaxOut(maxOut)
      .withMaxConnsPerPeer(maxConnsPerPeer)
      .withMplex(inTimeout, outTimeout)
      .withNoise()
      .withTcpTransport(transportFlags)
      .withNameResolver(nameResolver)
    if privKey.isSome():
      b = b.withPrivateKey(privKey.get())
    if wsEnabled == true:
      b = b.withAddresses(@[wsAddress, address])
      b = b.withWsTransport()
    else :
      b = b.withAddress(address)

    b.build()