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

when libp2p_secure == "noise":
  import libp2p/protocols/secure/noise
else:
  import libp2p/protocols/secure/secio

export
  switch, peer, peerinfo, connection, multiaddress, crypto

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
                        triggerSelf = false,
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
  when libp2p_secure == "noise":
    let secureManagers = {NoiseCodec: newNoise(seckey).Secure}.toTable
  else:
    let secureManagers = {SecioCodec: newSecio(seckey).Secure}.toTable
  let pubSub = PubSub newPubSub(WakuSub, peerInfo, triggerSelf)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = some(pubSub))
