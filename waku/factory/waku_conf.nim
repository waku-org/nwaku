import
  std/[net, options, strutils],
  chronicles,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
  secp256k1,
  results

import
  ../waku_rln_relay/rln_relay,
  ../waku_api/rest/builder,
  ../discovery/waku_discv5,
  ../node/waku_metrics,
  ../common/logging,
  ../waku_enr/capabilities

export RlnRelayConf, RlnRelayCreds, RestServerConf, Discv5Conf, MetricsServerConf

logScope:
  topics = "waku conf"

# TODO: should be defined in validator_signed.nim and imported here
type ProtectedShard* {.requiresInit.} = object
  shard*: uint16
  key*: secp256k1.SkPublicKey

type DnsDiscoveryConf* {.requiresInit.} = object
  enrTreeUrl*: string
  # TODO: should probably only have one set of name servers (see dnsaddrs) 
  nameServers*: seq[IpAddress]

type StoreSyncConf* {.requiresInit.} = object
  rangeSec*: uint32
  intervalSec*: uint32
  relayJitterSec*: uint32

type StoreServiceConf* {.requiresInit.} = object
  dbMigration*: bool
  dbURl*: string
  dbVacuum*: bool
  supportV2*: bool
  maxNumDbConnections*: int
  retentionPolicy*: string
  resume*: bool
  storeSyncConf*: Option[StoreSyncConf]

type FilterServiceConf* {.requiresInit.} = object
  maxPeersToServe*: uint32
  subscriptionTimeout*: uint16
  maxCriteria*: uint32

type WebSocketSecureConf* {.requiresInit.} = object
  keyPath*: string
  certPath*: string

type WebSocketConf* = object
  port*: Port
  secureConf*: Option[WebSocketSecureConf]

type NetworkConfig* = object # TODO: make enum
  natStrategy*: string
  p2pTcpPort*: Port
  dns4DomainName*: Option[string]
  p2pListenAddress*: IpAddress
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: bool

## `WakuConf` is a valid configuration for a Waku node
## All information needed by a waku node should be contained
## In this object. A convenient `validate` method enables doing
## sanity checks beyond type enforcement.
## If `Option` is `some` it means the related protocol is enabled.
type WakuConf* {.requiresInit.} = ref object
  # ref because `getRunningNetConfig` modifies it
  nodeKey*: crypto.PrivateKey

  clusterId*: uint16
  shards*: seq[uint16]
  protectedShards*: seq[ProtectedShard]

  # TODO: move to an autoShardingConf
  numShardsInNetwork*: uint32
  contentTopics*: seq[string]

  relay*: bool
  lightPush*: bool
  peerExchange*: bool

  # TODO: remove relay peer exchange
  relayPeerExchange*: bool
  rendezvous*: bool
  circuitRelayClient*: bool
  keepAlive*: bool

  discv5Conf*: Option[Discv5Conf]
  dnsDiscoveryConf*: Option[DnsDiscoveryConf]
  filterServiceConf*: Option[FilterServiceConf]
  storeServiceConf*: Option[StoreServiceConf]
  rlnRelayConf*: Option[RlnRelayConf]
  restServerConf*: Option[RestServerConf]
  metricsServerConf*: Option[MetricsServerConf]
  webSocketConf*: Option[WebSocketConf]

  portsShift*: uint16
  dnsAddrs*: bool
  dnsAddrsNameServers*: seq[IpAddress]
  networkConf*: NetworkConfig
  wakuFlags*: CapabilitiesBitfield

  # TODO: could probably make it a `PeerRemoteInfo`
  staticNodes*: seq[string]
  remoteStoreNode*: Option[string]
  remoteLightPushNode*: Option[string]
  remoteFilterNode*: Option[string]
  remotePeerExchangeNode*: Option[string]

  maxMessageSizeBytes*: uint64

  logLevel*: logging.LogLevel
  logFormat*: logging.LogFormat

  peerPersistence*: bool
  # TODO: should clearly be a uint
  peerStoreCapacity*: Option[int]
  # TODO: should clearly be a uint
  maxConnections*: int

  agentString*: string

  colocationLimit*: int

  # TODO: use proper type
  rateLimits*: seq[string]

  # TODO: those could be in a relay conf object
  maxRelayPeers*: Option[int]
  relayShardedPeerManagement*: bool
  # TODO: use proper type
  relayServiceRatio*: string

  p2pReliability*: bool

proc logConf*(conf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelayConf.isSome,
    store = conf.storeServiceConf.isSome,
    filter = conf.filterServiceConf.isSome,
    lightPush = conf.lightPush,
    peerExchange = conf.peerExchange

  info "Configuration. Network", cluster = conf.clusterId

  for shard in conf.shards:
    info "Configuration. Shards", shard = shard

  if conf.discv5Conf.isSome():
    for i in conf.discv5Conf.get().bootstrapNodes:
      info "Configuration. Bootstrap nodes", node = i.string

  if conf.rlnRelayConf.isSome():
    var rlnRelayConf = conf.rlnRelayConf.get()
    if rlnRelayConf.dynamic:
      info "Configuration. Validation",
        mechanism = "onchain rln",
        contract = rlnRelayConf.ethContractAddress.string,
        maxMessageSize = conf.maxMessageSizeBytes,
        rlnEpochSizeSec = rlnRelayConf.epochSizeSec,
        rlnRelayUserMessageLimit = rlnRelayConf.userMessageLimit,
        rlnRelayEthClientAddress = string(rlnRelayConf.ethClientAddress)

proc validateNodeKey(wakuConf: WakuConf): Result[void, string] =
  wakuConf.nodeKey.getPublicKey().isOkOr:
    return err("Node key is invalid")
  return ok()

proc validateShards(wakuConf: WakuConf): Result[void, string] =
  let numShardsInNetwork = wakuConf.numShardsInNetwork

  # TODO: fix up this behaviour
  if numShardsInNetwork == 0:
    return ok()

  for shard in wakuConf.shards:
    if shard >= numShardsInNetwork:
      let msg =
        "validateShards invalid shard: " & $shard & " when numShardsInNetwork: " &
        $numShardsInNetwork # fmt doesn't work
      error "validateShards failed", error = msg
      return err(msg)

  return ok()

proc validateNoEmptyStrings(wakuConf: WakuConf): Result[void, string] =
  if wakuConf.networkConf.dns4DomainName.isSome and
      isEmptyOrWhiteSpace(wakuConf.networkConf.dns4DomainName.get().string):
    return err("dns4DomainName is an empty string, set it to none(string) instead")

  if isEmptyOrWhiteSpace(wakuConf.relayServiceRatio):
    return err("relayServiceRatio is an empty string")

  for sn in wakuConf.staticNodes:
    if isEmptyOrWhiteSpace(sn):
      return err("staticNodes contain an empty string")

  if wakuConf.remoteStoreNode.isSome and
      isEmptyOrWhiteSpace(wakuConf.remoteStoreNode.get()):
    return err("remoteStoreNode is an empty string, set it to none(string) instead")

  if wakuConf.remoteLightPushNode.isSome and
      isEmptyOrWhiteSpace(wakuConf.remoteLightPushNode.get()):
    return err("remoteLightPushNode is an empty string, set it to none(string) instead")

  if wakuConf.remotePeerExchangeNode.isSome and
      isEmptyOrWhiteSpace(wakuConf.remotePeerExchangeNode.get()):
    return
      err("remotePeerExchangeNode is an empty string, set it to none(string) instead")

  if wakuConf.remoteFilterNode.isSome and
      isEmptyOrWhiteSpace(wakuConf.remoteFilterNode.get()):
    return
      err("remotePeerExchangeNode is an empty string, set it to none(string) instead")

  if wakuConf.dnsDiscoveryConf.isSome and
      isEmptyOrWhiteSpace(wakuConf.dnsDiscoveryConf.get().enrTreeUrl):
    return err ("dnsDiscoveryConf.enrTreeUrl is an empty string")

  # TODO: rln relay config should validate itself
  if wakuConf.rlnRelayConf.isSome():
    let rlnRelayConf = wakuConf.rlnRelayConf.get()

    if isEmptyOrWhiteSpace(rlnRelayConf.treePath):
      return err("rlnRelayConf.treepath is an empty string")
    if isEmptyOrWhiteSpace(rlnRelayConf.ethClientAddress):
      return err("rlnRelayConf.ethClientAddress is an empty string")
    if isEmptyOrWhiteSpace(rlnRelayConf.ethContractAddress):
      return err("rlnRelayConf.ethContractAddress is an empty string")

    if rlnRelayConf.creds.isSome():
      let creds = rlnRelayConf.creds.get()
      if isEmptyOrWhiteSpace(creds.path):
        return err (
          "rlnRelayConf.creds.path is an empty string, set rlnRelayConf.creds it to none instead"
        )
      if isEmptyOrWhiteSpace(creds.password):
        return err (
          "rlnRelayConf.creds.password is an empty string, set rlnRelayConf.creds to none instead"
        )

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateNodeKey()
  ?wakuConf.validateShards()
  ?wakuConf.validateNoEmptyStrings()
  return ok()
