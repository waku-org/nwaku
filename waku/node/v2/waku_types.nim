import
  chronos,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/peerinfo,
  standard_setup

# Core Waku data types are defined here to avoid recursive dependencies.
#
# TODO Move more common data types here

type
  Topic* = string
  Message* = seq[byte]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    switch*: Switch
    # XXX Unclear if we need this
    peerInfo*: PeerInfo
    libp2pTransportLoops*: seq[Future[void]]
    messages*: seq[(Topic, Message)]

  WakuMessage* =
    payload*: seq[byte]
    contentTopic*: string
