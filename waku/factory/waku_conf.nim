import
  std/[net, options, strutils],
  chronicles,
  libp2p/crypto/crypto,
  libp2p/multiaddress,
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

# TODO: this should come from discv5 discovery module
type Discv5Conf* = ref object
  bootstrapNodes*: seq[TextEnr]
  udpPort*: Port

# TODO: this should come from RLN relay module
type RlnRelayConf* = ref object
  ethContractAddress*: ContractAddress
  chainId*: uint
  dynamic*: bool
  bandwidthThreshold*: int
  epochSizeSec*: uint64
  userMessageLimit*: uint64
  ethClientAddress*: EthRpcUrl

## `WakuConf` is a valid configuration for a Waku node
## All information needed by a waku node should be contained
## In this object. A convenient `validate` method enables doing
## sanity checks beyond type enforcement.
type WakuConf* = ref object
  nodeKey*: PrivateKey

  clusterId*: uint16
  numShardsInNetwork*: uint32
  shards*: seq[uint16]

  relay*: bool
  store*: bool
  filter*: bool
  lightPush*: bool
  peerExchange*: bool

  discv5Conf*: Option[Discv5Conf]

  rlnRelayConf*: Option[RlnRelayConf]

  maxMessageSizeBytes*: int

  logLevel*: logging.LogLevel
  logFormat*: logging.LogFormat

  natStrategy*: NatStrategy

  tcpPort*: Port
  portsShift*: uint16
  dns4DomainName*: Option[DomainName]
  extMultiAddrs*: seq[MultiAddress]

proc log*(conf: WakuConf) =
  info "Configuration: Enabled protocols",
    relay = conf.relay,
    rlnRelay = conf.rlnRelayConf.isSome,
    store = conf.store,
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
  if wakuConf.dns4DomainName.isSome():
    if isEmptyOrWhiteSpace(wakuConf.dns4DomainName.get().string):
      return err("dns4DomainName is an empty string, set it to none(string) instead")

  return ok()

proc validate*(wakuConf: WakuConf): Result[void, string] =
  ?wakuConf.validateShards()
  ?wakuConf.validateNoEmptyStrings()

  return ok()
