# Waku Switch utils.
{.push raises: [TLSStreamProtocolError, Defect].}
import
  std/[options, sequtils, strutils],
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

proc getSecureKey(path : string): TLSPrivateKey =
  doAssert isEmptyOrWhitespace(path) == false
  try :
    let keyString : string = readFile(path)
    let key : TLSPrivateKey = TLSPrivateKey.init(keyString)
    return key
  except:
    raise newException(TLSStreamProtocolError,"key init failed")

proc getSecureCert(path : string): TLSCertificate =
  doAssert isEmptyOrWhitespace(path) == false
  try :
    let certString: string = readFile(path)
    let cert : TLSCertificate = TLSCertificate.init(certString)
    return cert
  except:
    raise newException(TLSStreamProtocolError,"Cert init failed")

proc withWssTransport*(b: SwitchBuilder,
                        secureKeyPath: string,
                        secureCertPath: string): SwitchBuilder =
  let key : TLSPrivateKey =  getSecureKey(secureKeyPath)
  let cert : TLSCertificate = getSecureCert(secureCertPath)
  b.withTransport(proc(upgr: Upgrade): Transport = WsTransport.new(upgr,
                  tlsPrivateKey = key,
                  tlsCertificate = cert,
                  {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName}))



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
    wsEnabled: bool = false,
    wssEnabled: bool = false,
    secureKeyPath: string = "",
    secureCertPath: string = ""): Switch
    {.raises: [Defect,TLSStreamProtocolError, LPError].} =

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
    if wssEnabled == true:
      b = b.withAddresses(@[wsAddress, address])
      b = b.withWssTransport(secureKeyPath, secureCertPath)
    else :
      b = b.withAddress(address)

    b.build()