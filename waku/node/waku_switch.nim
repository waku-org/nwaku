# Waku Switch utils.
when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[options, math],
  chronos, chronicles,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/rendezvous,
  libp2p/nameresolving/nameresolver,
  libp2p/builders,
  libp2p/switch,
  libp2p/transports/[transport, tcptransport, wstransport]

# override nim-libp2p default value (which is also 1)
const MaxConnectionsPerPeer* = 1

proc withWsTransport*(b: SwitchBuilder): SwitchBuilder =
  b.withTransport(proc(upgr: Upgrade): Transport = WsTransport.new(upgr))

proc getSecureKey(path : string): TLSPrivateKey
  {.raises: [Defect, IOError].} =

  trace "Key path is.", path=path
  let stringkey: string = readFile(path)
  try:
    let key = TLSPrivateKey.init(stringkey)
    return key
  except TLSStreamProtocolError as exc:
    debug "exception raised from getSecureKey", msg=exc.msg

proc getSecureCert(path : string): TLSCertificate
  {.raises: [Defect, IOError].} =

  trace "Certificate path is.", path=path
  let stringCert: string = readFile(path)
  try:
    let cert  = TLSCertificate.init(stringCert)
    return cert
  except TLSStreamProtocolError as exc:
    debug "exception raised from getSecureCert", msg=exc.msg

proc withWssTransport*(b: SwitchBuilder,
                        secureKeyPath: string,
                        secureCertPath: string): SwitchBuilder
  {.raises: [Defect, IOError].} =

  let key : TLSPrivateKey =  getSecureKey(secureKeyPath)
  let cert : TLSCertificate = getSecureCert(secureCertPath)
  b.withTransport(proc(upgr: Upgrade): Transport = WsTransport.new(upgr,
                  tlsPrivateKey = key,
                  tlsCertificate = cert,
                  {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName}))

proc newWakuSwitch*(
    privKey = none(crypto.PrivateKey),
    address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    wsAddress = none(MultiAddress),
    secureManagers: openarray[SecureProtocol] = [
        SecureProtocol.Noise,
      ],
    transportFlags: set[ServerFlags] = {},
    rng: ref HmacDrbgContext,
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    maxConnections = MaxConnections,
    maxIn = -1,
    maxOut = -1,
    maxConnsPerPeer = MaxConnectionsPerPeer,
    nameResolver: NameResolver = nil,
    sendSignedPeerRecord = false,
    wssEnabled: bool = false,
    secureKeyPath: string = "",
    secureCertPath: string = "",
    agentString = none(string),    # defaults to nim-libp2p version
    peerStoreCapacity = none(int), # defaults to 1.25 maxConnections
    services: seq[switch.Service] = @[],
    rendezvous: RendezVous = nil,
    ): Switch
    {.raises: [Defect, IOError, LPError].} =

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
      .withSignedPeerRecord(sendSignedPeerRecord)
      .withCircuitRelay()
      .withAutonat()

    if peerStoreCapacity.isSome():
      b = b.withPeerStore(peerStoreCapacity.get())
    else:
      let defaultPeerStoreCapacity = int(maxConnections)*5
      b = b.withPeerStore(defaultPeerStoreCapacity)
    if agentString.isSome():
      b = b.withAgentVersion(agentString.get())
    if privKey.isSome():
      b = b.withPrivateKey(privKey.get())
    if wsAddress.isSome():
      b = b.withAddresses(@[wsAddress.get(), address])

      if wssEnabled:
        b = b.withWssTransport(secureKeyPath, secureCertPath)
      else:
        b = b.withWsTransport()

    else :
      b = b.withAddress(address)

    if services.len > 0:
      b = b.withServices(services)

    if not rendezvous.isNil():
      b = b.withRendezVous(rendezvous)

    b.build()
