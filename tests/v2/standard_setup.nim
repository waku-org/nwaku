# compile time options here
const
  libp2p_secure {.strdefine.} = ""
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true

import
  options, tables, chronicles, chronos,
  libp2p/[switch, peer, peerinfo, connection, multiaddress, crypto/crypto],
  libp2p/transports/[transport, tcptransport],
  libp2p/muxers/[muxer, mplex/mplex, mplex/types],
  libp2p/protocols/[identify, secure/secure],
  libp2p/protocols/pubsub/[pubsub, gossipsub],
  ../../waku/protocol/v2/waku_protocol

import
  libp2p/protocols/secure/noise,
  libp2p/protocols/secure/secio

export
  switch, peer, peerinfo, connection, multiaddress, crypto

type
  SecureProtocol* {.pure.} = enum
    Noise,
    Secio

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
                        triggerSelf = false,
                        secureManagers: openarray[SecureProtocol] = [
                        # NOTE below relates to Eth2
                        # TODO investigate why we're getting fewer peers on public testnets with noise
                          SecureProtocol.Secio,
                          SecureProtocol.Noise, # array cos order matters
                        ],
                        verifySignature = libp2p_pubsub_verify,
                        sign = libp2p_pubsub_sign,
                        transportFlags: set[ServerFlags] = {}): Switch =
  info "newStandardSwitch"
  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let
    seckey = privKey.get(otherwise = PrivateKey.random(ECDSA).tryGet())
    peerInfo = PeerInfo.init(seckey, [address])
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(TcpTransport.init(transportFlags))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)

  var
    secureManagerInstances: seq[Secure]
  for sec in secureManagers:
    case sec
    of SecureProtocol.Noise:
      secureManagerInstances &= newNoise(seckey).Secure
    of SecureProtocol.Secio:
      secureManagerInstances &= newSecio(seckey).Secure

  let pubSub = PubSub newPubSub(WakuSub, peerInfo, triggerSelf)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagerInstances,
                     pubSub = some(pubSub))
