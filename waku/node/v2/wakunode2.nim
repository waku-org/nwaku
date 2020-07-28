import
  confutils, config, strutils, chronos, json_rpc/rpcserver, metrics,
  chronicles/topics_registry, # TODO: What? Need this for setLoglevel, weird.
  eth/[keys, p2p], eth/net/nat,
  eth/p2p/[discovery, enode],
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/peerinfo,
  stew/shims/net as stewNet,
  rpc/wakurpc,
  ../../protocol/v2/waku_protocol2,
  # TODO: Pull out standard switch from tests
  ../../tests/v2/standard_setup,
  waku_types

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # NOTE: based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    switch*: Switch
    # XXX: Unclear if we need this
    peerInfo*: PeerInfo
    libp2pTransportLoops*: seq[Future[void]]

const clientId = "Nimbus waku node"

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

# NOTE Any difference here in Waku vs Eth2?
# E.g. Devp2p/Libp2p support, etc.
#func asLibp2pKey*(key: keys.PublicKey): PublicKey =
#  PublicKey(scheme: Secp256k1, skkey: secp.SkPublicKey(key))

func asEthKey*(key: PrivateKey): keys.PrivateKey =
  keys.PrivateKey(key.skkey)

proc initAddress(T: type MultiAddress, str: string): T =
  let address = MultiAddress.init(str).tryGet()
  if IPFS.match(address) and matchPartial(multiaddress.TCP, address):
    result = address
  else:
    raise newException(ValueError,
                       "Invalid bootstrap node multi-address")

template tcpEndPoint(address, port): auto =
  MultiAddress.init(address, tcpProtocol, port)

proc dialPeer(p: WakuProto, address: string) {.async.} =
  info "dialPeer", address = address
  # XXX: This turns ipfs into p2p, not quite sure why
  let multiAddr = MultiAddress.initAddress(address)
  info "multiAddr", ma = multiAddr
  let parts = address.split("/")
  let remotePeer = PeerInfo.init(parts[^1], [multiAddr])

  info "Dialing peer", multiAddr
  p.conn = await p.switch.dial(remotePeer, WakuSubCodec)
  info "Post switch dial"
  # Isn't there just one p instance? Why connected here?
  p.connected = true

proc connectToNodes(p: WakuProto, nodes: openArray[string]) =
  for nodeId in nodes:
    info "connectToNodes", node = nodeId
    # XXX: This seems...brittle
    discard dialPeer(p, nodeId)
    # Waku 1
    #    let whisperENode = ENode.fromString(nodeId).expect("correct node")
    #    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

# NOTE Identical with eth2_network, pull out into common?
# NOTE Except portsShift
proc setupNat(conf: WakuNodeConf): tuple[ip: Option[ValidIpAddress],
                                           tcpPort: Port,
                                           udpPort: Port] {.gcsafe.} =
  # defaults
  result.tcpPort = Port(uint16(conf.tcpPort) + conf.portsShift)
  result.udpPort = Port(uint16(conf.udpPort) + conf.portsShift)

  var nat: NatStrategy
  case conf.nat.toLowerAscii:
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if conf.nat.startsWith("extip:"):
        try:
          # any required port redirection is assumed to be done by hand
          result.ip = some(ValidIpAddress.init(conf.nat[6..^1]))
          nat = NatNone
        except ValueError:
          error "nor a valid IP address", address = conf.nat[6..^1]
          quit QuitFailure
      else:
        error "not a valid NAT mechanism", value = conf.nat
        quit QuitFailure

  if nat != NatNone:
    let extIp = getExternalIP(nat)
    if extIP.isSome:
      result.ip = some(ValidIpAddress.init extIp.get)
      # TODO redirectPorts in considered a gcsafety violation
      # because it obtains the address of a non-gcsafe proc?
      let extPorts = ({.gcsafe.}:
        redirectPorts(tcpPort = result.tcpPort,
                      udpPort = result.udpPort,
                      description = clientId))
      if extPorts.isSome:
        (result.tcpPort, result.udpPort) = extPorts.get()

proc newWakuProto(switch: Switch): WakuProto =
  var wakuproto = WakuProto(switch: switch, codec: WakuSubCodec)

  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    let msg = cast[string](await conn.readLp(1024))
    await conn.writeLp("Hello!")
    await conn.close()

  wakuproto.handler = handle
  return wakuproto

# TODO Consider removing unused arguments
proc init*(T: type WakuNode, conf: WakuNodeConf, switch: Switch,
                   ip: Option[ValidIpAddress], tcpPort, udpPort: Port,
                   privKey: keys.PrivateKey,
                   peerInfo: PeerInfo): T =
  new result
  result.switch = switch
  result.peerInfo = peerInfo
  # TODO Peer pool, discovery, protocol state, etc

proc createWakuNode*(conf: WakuNodeConf): Future[WakuNode] {.async, gcsafe.} =
  var
    (extIp, extTcpPort, extUdpPort) = setupNat(conf)
    hostAddress = tcpEndPoint(conf.libp2pAddress, Port(uint16(conf.tcpPort) + conf.portsShift))
    announcedAddresses = if extIp.isNone(): @[]
                         else: @[tcpEndPoint(extIp.get(), extTcpPort)]

  info "Initializing networking", hostAddress,
                                  announcedAddresses

  let
    nodekey = conf.nodekey
    pubkey = nodekey.getKey.get()
    keys = KeyPair(seckey: nodekey, pubkey: pubkey)
    peerInfo = PeerInfo.init(nodekey)

  # XXX: Add this when we create node or start it?
  peerInfo.addrs.add(hostAddress)

  var switch = newStandardSwitch(some keys.seckey, hostAddress, triggerSelf = true)

  # TODO Either persist WakuNode or something here

  # TODO Look over this
  # XXX Consider asEthKey and asLibp2pKey
  result = WakuNode.init(conf, switch, extIp, extTcpPort, extUdpPort, keys.seckey.asEthKey, peerInfo)

proc start*(node: WakuNode, conf: WakuNodeConf) {.async.} =
  node.libp2pTransportLoops = await node.switch.start()

  let wakuProto = newWakuProto(node.switch)
  node.switch.mount(wakuProto)
  wakuProto.started = true

  # TODO Move out into separate proc
  if conf.rpc:
    let ta = initTAddress(conf.rpcAddress,
                          Port(conf.rpcPort + conf.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    setupWakuRPC(wakuProto, rpcServer)
    rpcServer.start()
    info "rpcServer started", ta=ta

  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  let id = peerInfo.peerId.pretty
  info "PeerInfo", id = id, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & id
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

  # XXX: So doing this _after_ other setup
  # Optionally direct connect with a set of nodes
  if conf.staticnodes.len > 0: connectToNodes(wakuProto, conf.staticnodes)

  # TODO Move out into separate proc
  when defined(insecure):
    if conf.metricsServer:
      let
        address = conf.metricsServerAddress
        port = conf.metricsServerPort + conf.portsShift
      info "Starting metrics HTTP server", address, port
      metrics.startHttpServer($address, Port(port))

    if conf.logMetrics:
      proc logMetrics(udata: pointer) {.closure, gcsafe.} =
        {.gcsafe.}:
          let
            connectedPeers = connected_peers.value
            totalMessages = total_messages.value

        info "Node metrics", connectedPeers, totalMessages
        addTimer(Moment.fromNow(2.seconds), logMetrics)
      addTimer(Moment.fromNow(2.seconds), logMetrics)

# TODO Get rid of this
# runForever()

#proc run(conf: WakuNodeConf) {.async, gcsafe.} =

## Public API
##

# TODO Take conf as a parameter and return a started WakuNode
#proc init*() {.async.} =
#  let conf = WakuNodeConf.load()
#  let network = await createWakuNode(conf)
#  waitFor network.start(conf)

method init*(conf: WakuNodeConf): Future[WakuNode] {.async.} =
  ## Creates and starts a Waku node.
  ##
  let node = await createWakuNode(conf)
  await node.start(conf)
  return node

type Topic* = string
type Message* = seq[byte]
type ContentFilter* = object
    contentTopic*: string
type TopicHandler* = proc(topic: Topic, message: Message)
type ContentFilterHandler* = proc(contentFilter: ContentFilter, message: Message)

type HistoryQuery = object
    xxx*: seq[byte]

type HistoryResponse = object
    xxx*: seq[byte]

method subscribe*(w: WakuNode, topic: Topic, handler: TopicHandler) =
  echo "NYI"
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and a `Message`.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_protocol`, and ensure Message is
  ## passed, not `data` field.

method subscribe*(w: WakuNode, contentFilter: ContentFilter, handler: ContentFilterHandler) =
  echo "NYI"
  ## Subscribes to a ContentFilter. Triggers handler when receiving messages on
  ## this content filter. ContentFilter is a method that takes some content
  ## filter, specifically with `ContentTopic`, and a `Message`. The `Message`
  ## has to match the `ContentTopic`.

  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_protocol` and `subscribe` above, and
  ## ensure Message is passed, not `data` field.

method unsubscribe*(w: WakuNode, topic: Topic) =
  echo "NYI"
  ## Unsubscribe from a topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

method unsubscribe*(w: WakuNode, contentFilter: ContentFilter) =
  echo "NYI"
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

method publish*(w: WakuNode, topic: Topic, message: Message) =
  echo "NYI"
  ## Publish a `Message` to a PubSub topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_protocol`, and ensure Message is
  ## passed, not `data` field.

method publish*(w: WakuNode, topic: Topic, contentFilter: ContentFilter, message: Message) =
  echo "NYI"
  ## Publish a `Message` to a PubSub topic with a specific content filter.
  ## Currently this means a `contentTopic`.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_protocol` and `publish`, and ensure
  ## Message is passed, not `data` field. Also ensure content filter is in
  ## Message.

method query*(w: WakuNode, query: HistoryQuery): HistoryResponse =
  echo "NYI"
  ## Queries for historical messages.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_protocol` and send `RPCMsg`.

when isMainModule:
  let conf = WakuNodeConf.load()
  discard init(conf)
  runForever()
