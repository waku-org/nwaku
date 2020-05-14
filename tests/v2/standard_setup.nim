# compile time options here
const
  libp2p_secure {.strdefine.} = ""

import
  options, tables,
  libp2p/[switch, peer, peerinfo, connection, multiaddress, crypto/crypto],
  libp2p/transports/[transport, tcptransport],
  libp2p/muxers/[muxer, mplex/mplex, mplex/types],
  libp2p/protocols/[identify, secure/secure],
  libp2p/protocols/pubsub/[pubsub, gossipsub, floodsub],
  ../../waku/protocol/v2/waku_protocol

when libp2p_secure == "noise":
  import libp2p/protocols/secure/noise
else:
  import libp2p/protocols/secure/secio

export
  switch, peer, peerinfo, connection, multiaddress, crypto

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0"),
                        triggerSelf = false,
                        gossip = false): Switch =
  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let
    seckey = privKey.get(otherwise = PrivateKey.random(ECDSA))
    peerInfo = PeerInfo.init(seckey, [address])
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(newTransport(TcpTransport))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)
  when libp2p_secure == "noise":
    let secureManagers = {NoiseCodec: newNoise(seckey).Secure}.toTable
  else:
    let secureManagers = {SecioCodec: newSecio(seckey).Secure}.toTable
  let pubSub = if gossip:
                 PubSub newPubSub(GossipSub, peerInfo, triggerSelf)
               else:
                 # Creating switch from generate node
                 # XXX: Hacky test, hijacking WakuSub here
                 # XXX: If I use WakuSub here I get a SIGSERV
                 #echo "Using WakuSub here"
                 #PubSub newPubSub(FloodSub, peerInfo, triggerSelf)
                 PubSub newPubSub(WakuSub, peerInfo, triggerSelf)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = some(pubSub))
