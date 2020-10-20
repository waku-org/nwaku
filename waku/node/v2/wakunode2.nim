import
  std/[options, tables],
  chronos, chronicles, stew/shims/net as stewNet,
  # TODO: Why do we need eth keys?
  eth/keys,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  # NOTE For TopicHandler, solve with exports?
  libp2p/protocols/pubsub/pubsub,
  libp2p/peerinfo,
  libp2p/standard_setup,
  ../../protocol/v2/[waku_relay, waku_store, waku_filter, message_notifier],
  ./waku_types

logScope:
  topics = "wakunode"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # TODO Get rid of this and use waku_types one
  Topic* = waku_types.Topic
  Message* = seq[byte]

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

## Public API
##

proc init*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port]()): T =
  ## Creates a Waku Node.
  ##
  ## Status: Implemented.
  ##
  let
    rng = crypto.newRng()
    hostAddress = tcpEndPoint(bindIp, bindPort)
    announcedAddresses = if extIp.isNone() or extPort.isNone(): @[]
                         else: @[tcpEndPoint(extIp.get(), extPort.get())]
    peerInfo = PeerInfo.init(nodekey)
  info "Initializing networking", hostAddress,
                                  announcedAddresses
  # XXX: Add this when we create node or start it?
  peerInfo.addrs.add(hostAddress)

  var switch = newStandardSwitch(some(nodekey), hostAddress,
    transportFlags = {ServerFlags.ReuseAddr}, rng = rng)
  # TODO Untested - verify behavior after switch interface change
  # More like this:
  # let pubsub = GossipSub.init(
  #    switch = switch,
  #    msgIdProvider = msgIdProvider,
  #    triggerSelf = true, sign = false,
  #    verifySignature = false).PubSub
  result = WakuNode(
    switch: switch,
    rng: rng,
    peerInfo: peerInfo,
    subscriptions: newTable[string, MessageNotificationSubscription](),
    filters: initTable[string, Filter]()
  )

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node.
  ##
  ## Status: Implemented.
  ##
  node.libp2pTransportLoops = await node.switch.start()

  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil:
    await node.wakuRelay.stop()

  await node.switch.stop()

proc subscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) {.async.} =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.
  info "subscribe", topic=topic

  let wakuRelay = node.wakuRelay
  await wakuRelay.subscribe(topic, handler)

proc subscribe*(node: WakuNode, request: FilterRequest, handler: ContentFilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  ##
  ## Status: Implemented.
  info "subscribe content", filter=request

  var id = generateRequestId(node.rng)
  if node.wakuFilter.isNil == false:
    # @TODO: ERROR HANDLING
    id = await node.wakuFilter.subscribe(request)
  node.filters[id] = Filter(contentFilters: request.contentFilters, handler: handler)

proc unsubscribe*(w: WakuNode, topic: Topic) =
  echo "NYI"
  ## Unsubscribe from a topic.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.

proc unsubscribe*(w: WakuNode, contentFilter: waku_types.ContentFilter) =
  echo "NYI"
  ## Unsubscribe from a content filter.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement.


proc publish*(node: WakuNode, topic: Topic, message: WakuMessage) =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.
  ##

  let wakuRelay = node.wakuRelay

  debug "publish", topic=topic, contentTopic=message.contentTopic
  let data = message.encode().buffer

  # XXX Consider awaiting here
  discard wakuRelay.publish(topic, data)

proc query*(node: WakuNode, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  ## Queries known nodes for historical messages. Triggers the handler whenever a response is received.
  ## QueryHandlerFunc is a method that takes a HistoryResponse.
  ##
  ## Status: Implemented.
  await node.wakuStore.query(query, handler)

# TODO Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.
  ##
  ## Status: Implemented.
  ##

  # TODO Generalize this for other type of multiaddresses
  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  let wakuInfo = WakuInfo(listenStr: listenStr)
  return wakuInfo

proc mountFilter*(node: WakuNode) =
  info "mounting filter"
  proc filterHandler(requestId: string, msg: MessagePush) {.gcsafe.} =
    info "push received"
    for message in msg.messages:
      node.filters.notify(message, requestId)

  node.wakuFilter = WakuFilter.init(node.switch, node.rng, filterHandler)
  node.switch.mount(node.wakuFilter)
  node.subscriptions.subscribe(WakuFilterCodec, node.wakuFilter.subscription())

proc mountStore*(node: WakuNode) =
  info "mounting store"
  node.wakuStore = WakuStore.init(node.switch, node.rng)
  node.switch.mount(node.wakuStore)
  node.subscriptions.subscribe(WakuStoreCodec, node.wakuStore.subscription())

proc mountRelay*(node: WakuNode, topics: seq[string] = newSeq[string]()) {.async, gcsafe.} =
  let wakuRelay = WakuRelay.init(
    switch = node.switch,
    # Use default
    #msgIdProvider = msgIdProvider,
    triggerSelf = true,
    sign = false,
    verifySignature = false
  )

  node.wakuRelay = wakuRelay
  node.switch.mount(wakuRelay)

  await sleepAsync(5.seconds)

  info "mounting relay"
  proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let msg = WakuMessage.init(data)
    if msg.isOk():
      node.filters.notify(msg.value(), "")
      await node.subscriptions.notify(topic, msg.value())

  await node.wakuRelay.subscribe("waku", relayHandler)

  for topic in topics:
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      debug "Hit handler", topic=topic, data=data

    # XXX: Is using discard here fine? Not sure if we want init to be async?
    # Can also move this to the start proc, possibly wiser?
    discard node.subscribe(topic, handler)


when isMainModule:
  import
    std/strutils,
    confutils, json_rpc/rpcserver, metrics,
    ./config, ./rpc/wakurpc, ../common

  proc parsePeerInfo(address: string): PeerInfo =
    let multiAddr = MultiAddress.initAddress(address)
    let parts = address.split("/")
    return PeerInfo.init(parts[^1], [multiAddr])

  proc dialPeer(n: WakuNode, address: string) {.async.} =
    info "dialPeer", address = address
    # XXX: This turns ipfs into p2p, not quite sure why
    let remotePeer = parsePeerInfo(address)

    info "Dialing peer", ma = remotePeer.addrs[0]
    # NOTE This is dialing on WakuRelay protocol specifically
    # TODO Keep track of conn and connected state somewhere (WakuRelay?)
    #p.conn = await p.switch.dial(remotePeer, WakuRelayCodec)
    #p.connected = true
    discard n.switch.dial(remotePeer, WakuRelayCodec)
    info "Post switch dial"

  proc setStorePeer(n: WakuNode, address: string) =
    info "dialPeer", address = address

    let remotePeer = parsePeerInfo(address)

    n.wakuStore.setPeer(remotePeer)

  proc setFilterPeer(n: WakuNode, address: string) =
    info "dialPeer", address = address

    let remotePeer = parsePeerInfo(address)

    n.wakuFilter.setPeer(remotePeer)

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

  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort)

  waitFor node.start()

  if conf.store:
    mountStore(node)
  
  if conf.filter:
    mountFilter(node)

  if conf.relay:
    waitFor mountRelay(node, conf.topics.split(" "))

  if conf.staticnodes.len > 0:
    connectToNodes(node, conf.staticnodes)

  if conf.storenode != "":
    setStorePeer(node, conf.storenode)

  if conf.filternode != "":
    setFilterPeer(node, conf.filternode)

  if conf.rpc:
    startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift))

  if conf.logMetrics:
    startMetricsLog()

  when defined(insecure):
    if conf.metricsServer:
      startMetricsServer(conf.metricsServerAddress,
        Port(conf.metricsServerPort + conf.portsShift))

  runForever()
