import
  bearssl/rand,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  ../protocol/waku_relay,
  ../protocol/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter,
  ../protocol/waku_lightpush,
  ../protocol/waku_rln_relay/waku_rln_relay_types, 
  ./peer_manager/peer_manager,
  ./discv5/waku_discv5
  

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # XXX: Weird type, should probably be using pubsub Topic object name?
  Topic* = string
  Message* = seq[byte]

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string
    #multiaddrStrings*: seq[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    wakuSwap*: WakuSwap
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    enr*: enr.Record
    libp2pPing*: Ping
    filters*: Filters
    rng*: ref rand.HmacDrbgContext
    wakuDiscv5*: WakuDiscoveryV5
    announcedAddresses* : seq[MultiAddress]
    started*: bool # Indicates that node has started listening
