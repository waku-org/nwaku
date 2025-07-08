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
  ../waku_enr/capabilities,
  ./network_conf

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

type NetworkConfig* = object # TODO: make enum
  natStrategy*: string
  p2pTcpPort*: Port
  dns4DomainName*: Option[string]
  p2pListenAddress*: IpAddress
  extMultiAddrs*: seq[MultiAddress]
  extMultiAddrsOnly*: bool

type EligibilityConf* = object
  enabled*: bool
  receiverAddress*: string
  paymentAmountWei*: uint32
  ethClientUrls*: seq[string]

type ReputationConf* = object
    enabled*: bool

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
  eligibilityConf*: Option[EligibilityConf]
  reputationConf*: Option[ReputationConf]

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

proc logConf*(wakuConf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = wakuConf.relay,
    rlnRelay = wakuConf.rlnRelayConf.isSome(),
    store = wakuConf.storeServiceConf.isSome(),
    filter = wakuConf.filterServiceConf.isSome(),
    lightPush = wakuConf.lightPush,
    peerExchange = wakuConf.peerExchange

  info "Configuration. Network", cluster = wakuConf.clusterId

  for shard in wakuConf.shards:
    info "Configuration. Shards", shard = shard

  if wakuConf.discv5Conf.isSome():
    for i in wakuConf.discv5Conf.get().bootstrapNodes:
      info "Configuration. Bootstrap nodes", node = i.string

  if wakuConf.rlnRelayConf.isSome():
    var rlnRelayConf = wakuConf.rlnRelayConf.get()
    if rlnRelayConf.dynamic:
      info "Configuration. Validation",
        mechanism = "onchain rln",
        contract = rlnRelayConf.ethContractAddress.string,
        maxMessageSize = wakuConf.maxMessageSizeBytes,
        rlnEpochSizeSec = rlnRelayConf.epochSizeSec,
        rlnRelayUserMessageLimit = rlnRelayConf.userMessageLimit,
        ethClientUrls = rlnRelayConf.ethClientUrls

  if wakuConf.eligibilityConf.isSome():
    let ec = wakuConf.eligibilityConf.get()
    debug "eligibility: EligibilityConf created", enabled = ec.enabled, receiverAddress = $ec.receiverAddress, paymentAmountWei = ec.paymentAmountWei, ethClientUrls = ec.ethClientUrls

proc validateNodeKey(wakuConf: WakuConf): Result[void, string] =
  wakuConf.nodeKey.getPublicKey().isOkOr:
    return err("nodekey param is invalid")
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
  if wakuConf.networkConf.dns4DomainName.isSome() and
      isEmptyOrWhiteSpace(wakuConf.networkConf.dns4DomainName.get().string):
    return err("dns4-domain-name is an empty string, set it to none(string) instead")

  if isEmptyOrWhiteSpace(wakuConf.relayServiceRatio):
    return err("relay-service-ratio is an empty string")

  for sn in wakuConf.staticNodes:
    if isEmptyOrWhiteSpace(sn):
      return err("staticnode contain an empty string")

  if wakuConf.remoteStoreNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteStoreNode.get()):
    return err("storenode is an empty string, set it to none(string) instead")

  if wakuConf.remoteLightPushNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteLightPushNode.get()):
    return err("lightpushnode is an empty string, set it to none(string) instead")

  if wakuConf.remotePeerExchangeNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remotePeerExchangeNode.get()):
    return err("peer-exchange-node is an empty string, set it to none(string) instead")

  if wakuConf.remoteFilterNode.isSome() and
      isEmptyOrWhiteSpace(wakuConf.remoteFilterNode.get()):
    return err("filternode is an empty string, set it to none(string) instead")

  if wakuConf.dnsDiscoveryConf.isSome() and
      isEmptyOrWhiteSpace(wakuConf.dnsDiscoveryConf.get().enrTreeUrl):
    return err("dns-discovery-url is an empty string")

  # TODO: rln relay config should validate itself
  if wakuConf.rlnRelayConf.isSome():
    let rlnRelayConf = wakuConf.rlnRelayConf.get()

    if isEmptyOrWhiteSpace(rlnRelayConf.treePath):
      return err("rln-relay-tree-path is an empty string")
    if rlnRelayConf.ethClientUrls.len == 0:
      return err("rln-relay-eth-client-address is empty")
    if isEmptyOrWhiteSpace(rlnRelayConf.ethContractAddress):
      return err("rln-relay-eth-contract-address is an empty string")

    if rlnRelayConf.creds.isSome():
      let creds = rlnRelayConf.creds.get()
      if isEmptyOrWhiteSpace(creds.path):
        return err ("rln-relay-cred-path is an empty string")
      if isEmptyOrWhiteSpace(creds.password):
        return err ("rln-relay-cred-password is an empty string")

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateNodeKey()
  ?wakuConf.validateShards()
  ?wakuConf.validateNoEmptyStrings()

  if wakuConf.eligibilityConf.isSome():
    let ec = wakuConf.eligibilityConf.get()
    debug "eligibility: EligibilityConf validation start"
    if ec.enabled:
      if not wakuConf.rlnRelayConf.isSome():
        debug "eligibility: EligibilityConf validation failed - RLN relay not enabled"
        return err("eligibility: RLN relay must be enabled if eligibility is enabled")
      if not wakuConf.lightPush:
        debug "eligibility: EligibilityConf validation failed - Lightpush not enabled"
        return err("eligibility: Lightpush must be enabled if eligibility is enabled")
      debug "eligibility: EligibilityConf validation successful"

  return ok()
