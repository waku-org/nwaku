import
  std/strutils,
  confutils,
  chronos,
  stew/shims/net
import
  libp2p/protocols/ping,
  libp2p/crypto/[crypto, secp]
import
  ../../waku/v2/node/peer_manager/peer_manager,
  ../../waku/v2/utils/peers,
  ../../waku/v2/node/wakunode2,
  ../../waku/v2/node/waku_payload,
  ../../waku/v2/utils/peers

# protocol each node shall support
const store_prot = "/vac/waku/store/"
const static_prot = "/vac/waku/relay/"
const lightpush_prot = "/vac/waku/lightpush/"
const filter_prot = "/vac/waku/filter/"

# cli flags
type
  WakuCanaryConf* = object
    staticnode* {.
      desc: "Multiaddress of a static node to attemp to dial",
      defaultValue: "",
      name: "staticnode" }: string

    storenode* {.
      desc: "Multiaddress of a store node to attemp to dial",
      defaultValue: "",
      name: "storenode" }: string

    timeout* {.
      desc: "Timeout to consider that the connection failed",
      defaultValue: chronos.seconds(10),
      name: "timeout" }: chronos.Duration

proc parseCmdArg*(T: type chronos.Duration, p: TaintedString): T =
  try:
      result = chronos.seconds(parseInt(p))
  except CatchableError as e:
    raise newException(ConfigurationError, "Invalid timeout value")

proc completeCmdArg*(T: type chronos.Duration, val: TaintedString): seq[string] =
  return @[]

proc validate_storenode(protocols: seq[string]): int = 
  for prot in protocols:
    if prot.startsWith(store_prot):
      info "Store protocol is supported", expected=store_prot, supported=prot
      return 0

  error "Store protocol is not supported", expected=store_prot, supported=protocols
  return 1

  # TODO: Extra checks, i.e. try to query the node
  #[
  setStorePeer(node, conf.storenode)
  const DefaultPubsubTopic = "/waku/2/default-waku/proto"
  const contentTopic = "/toy-chat/2/huilong/proto"

  # TODO: send a message before? or aassume that at least there is one?
  let queryRes = await node.query(
    HistoryQuery(
      contentFilters: @[HistoryContentFilter(
        contentTopic: contentTopic
        )]))
  echo queryRes
  echo queryRes.isOk()
  echo queryRes.value
  return 0
  ]#

proc validate_staticnode(protocols: seq[string]): int = 
  for prot in protocols:
    if prot.startsWith(static_prot):
      info "Static protocol is supported", expected=static_prot, supported=prot
      return 0
  error "Static protocol is not supported", expected=static_prot, supported=protocols

proc validate_lightpushnode(protocols: seq[string]): int = 
  echo "todo"
  return 1

proc validate_filternode(protocols: seq[string]): int =
  echo "todo:"
  return 1

proc main(): Future[int] {.async.} =
  let conf: WakuCanaryConf = WakuCanaryConf.load()
  info "Cli flags", cli=conf

  if conf.staticnode != "" and conf.storenode != "":
    error "only one flag staticnode/storenode can be used"
    return 1

  let
    nodeMulti = if conf.staticnode != "": conf.staticnode else: conf.storenode
    peer: RemotePeerInfo = parseRemotePeerInfo(nodeMulti)
    rng = crypto.newRng()
    nodeKey = crypto.PrivateKey.random(Secp256k1, rng[])[]
    node = WakuNode.new(nodeKey, ValidIpAddress.init("0.0.0.0"), Port(60000))

  await node.start()

  let timedOut = not await node.connectToNodes(@[peer]).withTimeout(conf.timeout)
  if timedOut:
    error "Timedout after", timeout=conf.timeout

  let lp2pPeerStore = node.switch.peerStore
  let conStatus = node.peerManager.peerStore.connectionBook[peer.peerId]

  if conStatus in [Connected, CanConnect]:
    let protocols = lp2pPeerStore[ProtoBook][peer.peerId]
    if conf.storenode != "":
      return validate_storenode(protocols)
    elif conf.staticnode != "":
      return validate_staticnode(protocols)        
  elif conStatus == CannotConnect:
    error "Could not connect", peerId = peer.peerId
    return 1
  return 0

let status = waitFor main()
quit status