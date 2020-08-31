import
  std/[strutils, options],
  chronos, confutils, json_rpc/rpcserver, metrics, stew/shims/net as stewNet,
  # TODO: Why do we need eth keys?
  eth/keys,
  # eth/[keys, p2p], eth/net/nat, eth/p2p/[discovery, enode],
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  # NOTE For TopicHandler, solve with exports?
  libp2p/protocols/pubsub/pubsub,
  libp2p/peerinfo,
  ../../protocol/v2/waku_relay, ../common,
  ./waku_types, ./config, ./standard_setup, ./rpc/wakurpc

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  Topic* = waku_types.Topic
  Message* = seq[byte]
  ContentFilter* = object
    contentTopic*: string

  HistoryQuery* = object
    topics*: seq[string]

  HistoryResponse* = object
    messages*: seq[Message]

const clientId = "Nimbus Waku v2 node"

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

proc dialPeer(n: WakuNode, address: string) {.async.} =
  info "dialPeer", address = address
  # XXX: This turns ipfs into p2p, not quite sure why
  let multiAddr = MultiAddress.initAddress(address)
  info "multiAddr", ma = multiAddr
  let parts = address.split("/")
  let remotePeer = PeerInfo.init(parts[^1], [multiAddr])

  info "Dialing peer", multiAddr
  # NOTE This is dialing on WakuRelay protocol specifically
  # TODO Keep track of conn and connected state somewhere (WakuRelay?)
  #p.conn = await p.switch.dial(remotePeer, WakuRelayCodec)
  #p.connected = true
  discard n.switch.dial(remotePeer, WakuRelayCodec)
  info "Post switch dial"

proc connectToNodes(n: WakuNode, nodes: openArray[string]) =
  for nodeId in nodes:
    info "connectToNodes", node = nodeId
    # XXX: This seems...brittle
    discard dialPeer(n, nodeId)
    # Waku 1
    #    let whisperENode = ENode.fromString(nodeId).expect("correct node")
    #    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

proc startRpc(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port) =
  let
    ta = initTAddress(rpcIp, rpcPort)
    rpcServer = newRpcHttpServer([ta])
  setupWakuRPC(node, rpcServer)
  rpcServer.start()
  info "RPC Server started", ta

proc startMetricsServer(serverIp: ValidIpAddress, serverPort: Port) =
    info "Starting metrics HTTP server", serverIp, serverPort
    metrics.startHttpServer($serverIp, serverPort)

proc startMetricsLog() =
  proc logMetrics(udata: pointer) {.closure, gcsafe.} =
    {.gcsafe.}:
      # TODO: libp2p_pubsub_peers is not public, so we need to make this either
      # public in libp2p or do our own peer counting after all.
      let
        totalMessages = total_messages.value

    info "Node metrics", totalMessages
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  discard setTimer(Moment.fromNow(2.seconds), logMetrics)

## Public API
##

proc init*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port]()): T =
  ## Creates and starts a Waku node.
  let
    hostAddress = tcpEndPoint(bindIp, bindPort)
    announcedAddresses = if extIp.isNone() or extPort.isNone(): @[]
                         else: @[tcpEndPoint(extIp.get(), extPort.get())]
    peerInfo = PeerInfo.init(nodekey)
  info "Initializing networking", hostAddress,
                                  announcedAddresses
  # XXX: Add this when we create node or start it?
  peerInfo.addrs.add(hostAddress)

  var switch = newStandardSwitch(some(nodekey), hostAddress, triggerSelf = true)

  return WakuNode(switch: switch, peerInfo: peerInfo)

proc start*(node: WakuNode) {.async.} =
  node.libp2pTransportLoops = await node.switch.start()

  # NOTE WakuRelay is being instantiated as part of creating switch with PubSub field set
  #
  # TODO Mount Waku Store and Waku Filter here

  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  let id = peerInfo.peerId.pretty
  info "PeerInfo", id = id, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & id
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

# NOTE TopicHandler is defined in pubsub.nim, roughly:
#type TopicHandler* = proc(topic: string, data: seq[byte])

type ContentFilterHandler* = proc(contentFilter: ContentFilter, message: Message)

proc subscribe*(w: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.

  let wakuRelay = w.switch.pubSub.get()
  # XXX Consider awaiting here
  discard wakuRelay.subscribe(topic, handler)

proc subscribe*(w: WakuNode, contentFilter: ContentFilter, handler: ContentFilterHandler) =
  echo "NYI"
  ## Subscribes to a ContentFilter. Triggers handler when receiving messages on
  ## this content filter. ContentFilter is a method that takes some content
  ## filter, specifically with `ContentTopic`, and a `Message`. The `Message`
  ## has to match the `ContentTopic`.

  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_filter` and `subscribe` above.

proc unsubscribe*(w: WakuNode, topic: Topic) =
  echo "NYI"
  ## Unsubscribe from a topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

proc unsubscribe*(w: WakuNode, contentFilter: ContentFilter) =
  echo "NYI"
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

proc publish*(w: WakuNode, topic: Topic, message: Message) =
  ## Publish a `Message` to a PubSub topic.
  ##
  ## Status: Partially implemented.
  ##
  ## TODO WakuMessage OR seq[byte]. NOT PubSub Message.
  let wakuSub = w.switch.pubSub.get()
  # XXX Consider awaiting here
  discard wakuSub.publish(topic, message)

proc publish*(w: WakuNode, topic: Topic, contentFilter: ContentFilter, message: Message) =
  ## Publish a `Message` to a PubSub topic with a specific content filter.
  ## Currently this means a `contentTopic`.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_relay` and `publish`.
  ## TODO WakuMessage. Ensure content filter is in it.

  w.messages.insert((contentFilter.contentTopic, message))

  let wakuSub = w.switch.pubSub.get()
  # XXX Consider awaiting here

  discard wakuSub.publish(topic, message)

proc query*(w: WakuNode, query: HistoryQuery): HistoryResponse =
  ## Queries for historical messages.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_store` and send RPC.
  result.messages = newSeq[Message]()

  for msg in w.messages:
    if msg[0] notin query.topics:
      continue

    result.messages.insert(msg[1])

when isMainModule:
  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  waitFor node.start()

  if conf.staticnodes.len > 0:
    connectToNodes(node, conf.staticnodes)

  if conf.rpc:
    startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift))

  if conf.logMetrics:
    startMetricsLog()

  when defined(insecure):
    if conf.metricsServer:
      startMetricsServer(conf.metricsServerAddress,
        Port(conf.metricsServerPort + conf.portsShift))

  runForever()
