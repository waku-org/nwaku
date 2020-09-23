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
    extIp = none[ValidIpAddress](), extPort = none[Port](), topics = newSeq[string]()): T =
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

  var switch = newStandardSwitch(some(nodekey), hostAddress)
  # TODO Untested - verify behavior after switch interface change
  # More like this:
  # let pubsub = GossipSub.init(
  #    switch = switch,
  #    msgIdProvider = msgIdProvider,
  #    triggerSelf = true, sign = false,
  #    verifySignature = false).PubSub
  let wakuRelay = WakuRelay.init(
    switch = switch,
    # Use default
    #msgIdProvider = msgIdProvider,
    triggerSelf = true,
    sign = false,
    verifySignature = false)
  # This gets messy with: .PubSub
  switch.mount(wakuRelay)

  result = WakuNode(
    switch: switch, 
    peerInfo: peerInfo,
    wakuRelay: wakuRelay,
    subscriptions: newTable[string, MessageNotificationSubscription]()
  )

  for topic in topics:
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      debug "Hit handler", topic=topic, data=data

    # XXX: Is using discard here fine? Not sure if we want init to be async?
    # Can also move this to the start proc, possibly wiser?
    discard result.subscribe(topic, handler)

proc start*(node: WakuNode) {.async.} =
  node.libp2pTransportLoops = await node.switch.start()

  # NOTE WakuRelay is being instantiated as part of initing node
  node.wakuStore = WakuStore.init()
  node.switch.mount(node.wakuStore)
  node.subscriptions.subscribe(WakuStoreCodec, node.wakuStore.subscription())

<<<<<<< HEAD
  node.wakuFilter = WakuFilter.init(node.switch)
=======
  proc pushHandler(msg: MessagePush) {.async, gcsafe.} =
    info "push received"

  node.wakuFilter = WakuFilter.init(node.switch, pushHandler)
>>>>>>> master
  node.switch.mount(node.wakuFilter)
  node.subscriptions.subscribe(WakuFilterCodec, node.wakuFilter.subscription())

  proc relayHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let msg = WakuMessage.init(data)
    if msg.isOk():
      await node.subscriptions.notify(topic, msg.value())

  await node.wakuRelay.subscribe("waku", relayHandler)

  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[0] & "/p2p/" & $peerInfo.peerId
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

proc stop*(node: WakuNode) {.async.} =
  let wakuRelay = node.wakuRelay
  await wakuRelay.stop()

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

proc subscribe*(node: WakuNode, contentFilter: waku_types.ContentFilter, handler: ContentFilterHandler) {.async.} =
  ## Subscribes to a ContentFilter. Triggers handler when receiving messages on
  ## this content filter. ContentFilter is a method that takes some content
  ## filter, specifically with `ContentTopic`, and a `Message`. The `Message`
  ## has to match the `ContentTopic`.
  info "subscribe content", contentFilter=contentFilter

  # TODO: get some random id, or use the Filter directly as key
  node.filters.add("some random id", Filter(contentFilter: contentFilter, handler: handler))

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

proc query*(w: WakuNode, query: HistoryQuery): HistoryResponse =
  ## Queries for historical messages.
  ##
  ## Status: Not yet implemented.
  ## TODO Implement as wrapper around `waku_store` and send RPC.
  
  # XXX Unclear how this should be hooked up, Message or WakuMessage?
  # result.messages.insert(msg[1])
  discard

when isMainModule:
  import
    std/strutils,
    confutils, json_rpc/rpcserver, metrics,
    ./config, ./rpc/wakurpc, ../common

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

  let
    conf = WakuNodeConf.load()
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    node = WakuNode.init(conf.nodeKey, conf.libp2pAddress,
      Port(uint16(conf.tcpPort) + conf.portsShift), extIp, extTcpPort, conf.topics.split(" "))

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
