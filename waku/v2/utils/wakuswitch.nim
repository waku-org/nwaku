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
  var
    stringkey : string = """
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCdNv0SX02aeZ4/
Yc+p/Kwd5UVOHlpmK7/TVC/kcjFbdoUuKNn8pnX/fyhgSKpUYut+te7YRiZhqlaL
EZKjfy8GBZwXZnJCevFkTvGTTebXXExLIsLGfJqKeLAdFCQkX8wV3jV1DT5JLV+D
5+HWaiiBr38gsl4ZbfyedTF40JvzokCmcdlx9bpzX1j/b84L/zSwUyyEcgp5G28F
Jh5TnxAeDHJpOVjr8XMb/xoNqiDF6NwF96hvOZC14mZ1TxxW5bUzXprsy0l52pmh
dN3Crz11+t2h519hRKHxT6/l5pTx/+dApXiP6hMV04CQJNnas3NyRxTDR9dNel+3
+wD7/PRTAgMBAAECggEBAJuXPEbegxMKog7gYoE9S6oaqchySc0sJyCjBPL2ANsg
JRZV38cnh0hhNDh2MfxqGd7Bd6wbYQjvZ88iiRm+WW+ARcby4MnimtxHNNYwFvG0
qt0BffqqftfkMYfV0x8coAJUdFtvy+DoQstsxhlJ3uTaJtrZLD/GlmjMWzXSX0Vy
FXiLDO7/LoSjsjaf4e4aLofIyLJS3H1T+5cr/d2mdpRzkeWkxShODsK4cRLOlZ5I
pz4Wm2770DTbiYph8ixl/CnmYn6T7V0F5VYujALknipUBeQY4e/A9vrQ/pvqJV+W
JjFUne6Rxg/lJjh8vNJp2bK1ZbzpwmZLaZIoEz8t/qECgYEAzvCCA48uQPaurSQ3
cvHDhcVwYmEaH8MW8aIW/5l8XJK60GsUHPFhEsfD/ObI5PJJ9aOqgabpRHkvD4ZY
a8QJBxCy6UeogUeKvGks8VQ34SZXLimmgrL9Mlljv0v9PloEkVYbztYyX4GVO0ov
3oH+hKO+/MclzNDyeXZx3Vv4K+UCgYEAwnyb7tqp7fRqm/8EymIZV5pa0p6h609p
EhCBi9ii6d/ewEjsBhs7bPDBO4PO9ylvOvryYZH1hVbQja2anOCBjO8dAHRHWM86
964TFriywBQkYxp6dsB8nUjLBDza2xAM3m+OGi9/ATuhEAe5sXp/fZL3tkfSaOXI
A7Gzro+kS9cCgYEAtKScSfEeBlWQa9H2mV9UN5z/mtF61YkeqTW+b8cTGVh4vWEL
wKww+gzqGAV6Duk2CLijKeSDMmO64gl7fC83VjSMiTklbhz+jbQeKFhFI0Sty71N
/j+y6NXBTgdOfLRl0lzhj2/JrzdWBtie6tR9UloCaXSKmb04PTFY+kvDWsUCgYBR
krJUnKJpi/qrM2tu93Zpp/QwIxkG+We4i/PKFDNApQVo4S0d4o4qQ1DJBZ/pSxe8
RUUkZ3PzWVZgFlCjPAcadbBUYHEMbt7sw7Z98ToIFmqspo53AIVD8yQzwtKIz1KW
eXPAx+sdOUV008ivCBIxOVNswPMfzED4S7Bxpw3iQQKBgGJhct2nBsgu0l2/wzh9
tpKbalW1RllgptNQzjuBEZMTvPF0L+7BE09/exKtt4N9s3yAzi8o6Qo7RHX5djVc
SNgafV4jj7jt2Ilh6KOy9dshtLoEkS1NmiqfVe2go2auXZdyGm+I2yzKWdKGDO0J
diTtYf1sA0PgNXdSyDC03TZl
-----END PRIVATE KEY-----
"""
  try :
    let key: TLSPrivateKey = TLSPrivateKey.init(stringkey)
    return key
  except:
    raise newException(TLSStreamProtocolError,"key init failed")
    
  


proc getSecureCert(path : string): TLSCertificate =
  #doAssert isEmptyOrWhitespace(path) == false
  var
    stringCert : string = """
-----BEGIN CERTIFICATE-----
MIIDazCCAlOgAwIBAgIUe9fr78Dz9PedQ5Sq0uluMWQhX9wwDQYJKoZIhvcNAQEL
BQAwRTELMAkGA1UEBhMCSU4xEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoM
GEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDAeFw0yMTAzMTcwOTMzMzZaFw0zMTAz
MTUwOTMzMzZaMEUxCzAJBgNVBAYTAklOMRMwEQYDVQQIDApTb21lLVN0YXRlMSEw
HwYDVQQKDBhJbnRlcm5ldCBXaWRnaXRzIFB0eSBMdGQwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQCdNv0SX02aeZ4/Yc+p/Kwd5UVOHlpmK7/TVC/kcjFb
doUuKNn8pnX/fyhgSKpUYut+te7YRiZhqlaLEZKjfy8GBZwXZnJCevFkTvGTTebX
XExLIsLGfJqKeLAdFCQkX8wV3jV1DT5JLV+D5+HWaiiBr38gsl4ZbfyedTF40Jvz
okCmcdlx9bpzX1j/b84L/zSwUyyEcgp5G28FJh5TnxAeDHJpOVjr8XMb/xoNqiDF
6NwF96hvOZC14mZ1TxxW5bUzXprsy0l52pmhdN3Crz11+t2h519hRKHxT6/l5pTx
/+dApXiP6hMV04CQJNnas3NyRxTDR9dNel+3+wD7/PRTAgMBAAGjUzBRMB0GA1Ud
DgQWBBRkSY1AkGUpVNxG5fYocfgFODtQmTAfBgNVHSMEGDAWgBRkSY1AkGUpVNxG
5fYocfgFODtQmTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQBt
D71VH7F8GOQXITFXCrHwEq1Fx3ScuSnL04NJrXw/e9huzLVQOchAYp/EIn4x2utN
S31dt94wvi/IysOVbR1LatYNF5kKgGj2Wc6DH0PswBMk8R1G8QMeCz+hCjf1VDHe
AAW1x2q20rJAvUrT6cRBQqeiMzQj0OaJbvfnd2hu0/d0DFkcuGVgBa2zlbG5rbdU
Jnq7MQfSaZHd0uBgiKkS+Zw6XaYfWfByCAGSnUqRdOChiJ2stFVLvu+9oQ+PJjJt
Er1u9bKTUyeuYpqXr2BP9dqphwu8R4NFVUg6DIRpMFMsybaL7KAd4hD22RXCvc0m
uLu7KODi+eW62MHqs4N2
-----END CERTIFICATE-----
"""

  try :
    let cert : TLSCertificate = TLSCertificate.init(stringCert)
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