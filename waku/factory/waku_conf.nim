import
  std/[net, options, strutils],
  chronicles,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  secp256k1,
  results

import ../common/logging

logScope:
  topics = "waku conf"

type
  TextEnr* = distinct string
  ContractAddress* = distinct string
  EthRpcUrl* = distinct string
  NatStrategy* = distinct string
  DomainName* = distinct string

# TODO: should be defined in validator_signed.nim and imported here
type ProtectedShard* = object
  shard*: uint16
  key*: secp256k1.SkPublicKey

# TODO: this should come from discv5 discovery module
type Discv5Conf* = ref object
  # TODO: This should probably be an option on the builder
  # But translated to everything else "false" on the config
  discv5Only*: bool
  bootstrapNodes*: seq[TextEnr]
  udpPort*: Port

type StoreServiceConf* = ref object
  legacy*: bool
  dbURl*: string
  dbVacuum*: bool
  dbMigration*: bool
  maxNumDbConnections*: int
  retentionPolicy*: string
  resume*: bool

# TODO: this should come from RLN relay module
type RlnRelayConf* = ref object
  ethContractAddress*: ContractAddress
  chainId*: uint
  credIndex*: Option[uint]
  dynamic*: bool
  bandwidthThreshold*: int
  epochSizeSec*: uint64
  userMessageLimit*: uint64
  ethClientAddress*: EthRpcUrl

type WebSocketSecureConf* = ref object
  keyPath*: string
  certPath*: string

type WebSocketConf* = ref object
  port*: Port
  secureConf*: Option[WebSocketSecureConf]

## `WakuConf` is a valid configuration for a Waku node
## All information needed by a waku node should be contained
## In this object. A convenient `validate` method enables doing
## sanity checks beyond type enforcement.
type WakuConf* = ref object
  nodeKey*: PrivateKey

  clusterId*: uint16
  shards*: seq[uint16]
  protectedShards*: seq[ProtectedShard]

  #TODO: move to an autoShardingConf
  numShardsInNetwork*: uint32
  contentTopics*: seq[string]

  relay*: bool
  filter*: bool
  lightPush*: bool
  peerExchange*: bool
  storeSync*: bool
  # TODO: remove relay peer exchange
  relayPeerExchange*: bool
  rendezvous*: bool

  discv5Conf*: Option[Discv5Conf]

  storeServiceConf*: Option[StoreServiceConf]

  rlnRelayConf*: Option[RlnRelayConf]

  #TODO: could probably make it a `PeerRemoteInfo` here
  remoteStoreNode*: Option[string]

  maxMessageSizeBytes*: int

  logLevel*: logging.LogLevel
  logFormat*: logging.LogFormat

  natStrategy*: NatStrategy

  p2pTcpPort*: Port
  p2pListenAddress*: IpAddress
  portsShift*: uint16
  dns4DomainName*: Option[DomainName]
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: bool
  webSocketConf*: Option[WebSocketConf]

  dnsAddrs*: bool
  dnsAddrsNameServers*: seq[IpAddress]
  peerPersistence*: bool
  # TODO: should clearly be a uint
  peerStoreCapacity*: Option[int]
  # TODO: should clearly be a uint
  maxConnections*: int

  agentString*: string

  colocationLimit*: int

  rateLimits*: seq[string]

  # TODO: those could be in a relay conf object
  maxRelayPeers*: Option[int]
  relayShardedPeerManagement*: bool
  relayServiceRatio*: string

proc log*(conf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelayConf.isSome,
    store = conf.storeServiceConf.isSome,
    filter = conf.filter,
    lightPush = conf.lightPush,
    peerExchange = conf.peerExchange

  info "Configuration. Network", cluster = conf.clusterId

  for shard in conf.shards:
    info "Configuration. Shards", shard = shard

  if conf.discv5Conf.isSome():
    for i in conf.discv5Conf.get().bootstrapNodes:
      info "Configuration. Bootstrap nodes", node = i.string

  if conf.rlnRelayConf.isSome:
    var rlnRelayConf = conf.rlnRelayConf.geT()
    if rlnRelayConf.dynamic:
      info "Configuration. Validation",
        mechanism = "onchain rln",
        contract = rlnRelayConf.ethContractAddress.string,
        maxMessageSize = conf.maxMessageSizeBytes,
        rlnEpochSizeSec = rlnRelayConf.epochSizeSec,
        rlnRelayUserMessageLimit = rlnRelayConf.userMessageLimit,
        rlnRelayEthClientAddress = string(rlnRelayConf.ethClientAddress)

proc validateShards(wakuConf: WakuConf): Result[void, string] =
  let numShardsInNetwork = wakuConf.numShardsInNetwork

  for shard in wakuConf.shards:
    if shard >= numShardsInNetwork:
      let msg =
        "validateShards invalid shard: " & $shard & " when numShardsInNetwork: " &
        $numShardsInNetwork # fmt doesn't work
      error "validateShards failed", error = msg
      return err(msg)

  return ok()

proc validateNoEmptyStrings(wakuConf: WakuConf): Result[void, string] =
  if wakuConf.dns4DomainName.isSome and
      isEmptyOrWhiteSpace(wakuConf.dns4DomainName.get().string):
    return err("dns4DomainName is an empty string, set it to none(string) instead")

  if isEmptyOrWhiteSpace(wakuConf.relayServiceRatio):
    return err("relayServiceRatio is an empty string")

  if wakuConf.remoteStoreNode.isSome and
      isEmptyOrWhiteSpace(wakuConf.remoteStoreNode.get()):
    return err("store node is an empty string, set it to none(string) instead")

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateShards()
  ?wakuConf.validateNoEmptyStrings()

  return ok()
