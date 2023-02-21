when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[hashes, options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/results,
  stew/byteutils,
  stew/shims/net as stewNet,
  eth/keys,
  nimcrypto,
  bearssl/rand,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/connectivity/autonat/client,
  libp2p/protocols/connectivity/autonat/service,
  libp2p/nameresolving/nameresolver,
  libp2p/builders,
  libp2p/multihash,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport
import
  ../protocol/waku_message,
  ../protocol/waku_relay,
  ../protocol/waku_archive,
  ../protocol/waku_store,
  ../protocol/waku_store/client as store_client,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter,
  ../protocol/waku_filter/client as filter_client,
  ../protocol/waku_lightpush,
  ../protocol/waku_lightpush/client as lightpush_client,
  ../protocol/waku_peer_exchange,
  ../utils/peers,
  ../utils/wakuenr,
  ../utils/time,
  ./peer_manager,
  ./dnsdisc/waku_dnsdisc,
  ./discv5/waku_discv5,
  ./wakuswitch

when defined(rln):
  import
    ../protocol/waku_rln_relay

declarePublicGauge waku_version, "Waku version info (in git describe format)", ["version"]
declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]
declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_px_peers, "number of peers (in the node's peerManager) supporting the peer exchange protocol"

logScope:
  topics = "waku node"


# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# Default Waku Filter Timeout
const WakuFilterTimeout: Duration = 1.days


# key and crypto modules different
type
  # XXX: Weird type, should probably be using pubsub PubsubTopic object name?
  Message* = seq[byte]

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string
    #multiaddrStrings*: seq[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuArchive*: WakuArchive
    wakuStore*: WakuStore
    wakuStoreClient*: WakuStoreClient
    wakuFilter*: WakuFilter
    wakuFilterClient*: WakuFilterClient
    wakuSwap*: WakuSwap
    when defined(rln):
      wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: ref rand.HmacDrbgContext
    wakuDiscv5*: WakuDiscoveryV5
    announcedAddresses* : seq[MultiAddress]
    started*: bool # Indicates that node has started listening

template ip4TcpEndPoint(address, port): MultiAddress =
  MultiAddress.init(address, tcpProtocol, port)

template dns4Ma(dns4DomainName: string): MultiAddress =
  MultiAddress.init("/dns4/" & dns4DomainName).tryGet()

template tcpPortMa(port: Port): MultiAddress =
  MultiAddress.init("/tcp/" & $port).tryGet()

template dns4TcpEndPoint(dns4DomainName: string, port: Port): MultiAddress =
  dns4Ma(dns4DomainName) & tcpPortMa(port)

template wsFlag(wssEnabled: bool): MultiAddress =
  if wssEnabled: MultiAddress.init("/wss").tryGet()
  else: MultiAddress.init("/ws").tryGet()

type NetConfig* = object
  hostAddress*: MultiAddress
  wsHostAddress*: Option[MultiAddress]
  hostExtAddress*: Option[MultiAddress]
  wsExtAddress*: Option[MultiAddress]
  wssEnabled*: bool
  extIp*: Option[ValidIpAddress]
  extPort*: Option[Port]
  dns4DomainName*: Option[string]
  announcedAddresses*: seq[MultiAddress]
  extMultiAddrs*: seq[MultiAddress]
  enrMultiAddrs*: seq[MultiAddress]
  enrIp*: Option[ValidIpAddress]
  enrPort*: Option[Port]
  discv5UdpPort*: Option[Port]
  wakuFlags*: Option[WakuEnrBitfield]
  bindIp*: ValidIpAddress
  bindPort*: Port

proc init*(
  T: type NetConfig,
  bindIp: ValidIpAddress,
  bindPort: Port,
  extIp = none(ValidIpAddress),
  extPort = none(Port),
  extMultiAddrs = newSeq[MultiAddress](),
  wsBindPort: Port = (Port)8000,
  wsEnabled: bool = false,
  wssEnabled: bool = false,
  dns4DomainName = none(string),
  discv5UdpPort = none(Port),
  wakuFlags = none(WakuEnrBitfield)
): T {.raises: [LPError]} =
  ## Initialize addresses
  let
    # Bind addresses
    hostAddress = ip4TcpEndPoint(bindIp, bindPort)
    wsHostAddress = if wsEnabled or wssEnabled: some(ip4TcpEndPoint(bindIp, wsbindPort) & wsFlag(wssEnabled))
                    else: none(MultiAddress)
    enrIp = if extIp.isSome(): extIp else: some(bindIp)
    enrPort = if extPort.isSome(): extPort else: some(bindPort)

  # Setup external addresses, if available
  var
    hostExtAddress, wsExtAddress = none(MultiAddress)

  if (dns4DomainName.isSome()):
    # Use dns4 for externally announced addresses
    hostExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), extPort.get()))

    if (wsHostAddress.isSome()):
      wsExtAddress = some(dns4TcpEndPoint(dns4DomainName.get(), wsBindPort) & wsFlag(wssEnabled))
  else:
    # No public domain name, use ext IP if available
    if extIp.isSome() and extPort.isSome():
      hostExtAddress = some(ip4TcpEndPoint(extIp.get(), extPort.get()))

      if (wsHostAddress.isSome()):
        wsExtAddress = some(ip4TcpEndPoint(extIp.get(), wsBindPort) & wsFlag(wssEnabled))

  var announcedAddresses = newSeq[MultiAddress]()

  if hostExtAddress.isSome():
    announcedAddresses.add(hostExtAddress.get())
  else:
    announcedAddresses.add(hostAddress) # We always have at least a bind address for the host

  # External multiaddrs that the operator may have configured
  if extMultiAddrs.len > 0:
    announcedAddresses.add(extMultiAddrs)

  if wsExtAddress.isSome():
    announcedAddresses.add(wsExtAddress.get())
  elif wsHostAddress.isSome():
    announcedAddresses.add(wsHostAddress.get())

  let
    # enrMultiaddrs are just addresses which cannot be represented in ENR, as described in
    # https://rfc.vac.dev/spec/31/#many-connection-types
    enrMultiaddrs = announcedAddresses.filterIt(it.hasProtocol("dns4") or
                                                it.hasProtocol("dns6") or
                                                it.hasProtocol("ws") or
                                                it.hasProtocol("wss"))

  return NetConfig(
    hostAddress: hostAddress,
    wsHostAddress: wsHostAddress,
    hostExtAddress: hostExtAddress,
    wsExtAddress: wsExtAddress,
    extIp: extIp,
    extPort: extPort,
    wssEnabled: wssEnabled,
    dns4DomainName: dns4DomainName,
    announcedAddresses: announcedAddresses,
    extMultiAddrs: extMultiAddrs,
    enrMultiaddrs: enrMultiaddrs,
    enrIp: enrIp,
    enrPort: enrPort,
    discv5UdpPort: discv5UdpPort,
    bindIp: bindIp,
    bindPort: bindPort,
    wakuFlags: wakuFlags)


proc getEnr*(netConfig: NetConfig,
             wakuDiscV5 = none(WakuDiscoveryV5),
             nodeKey: crypto.PrivateKey): enr.Record =
  if wakuDiscV5.isSome():
    return wakuDiscV5.get().protocol.getRecord()

  return enr.Record.init(nodekey,
                         netConfig.enrIp,
                         netConfig.enrPort,
                         netConfig.discv5UdpPort,
                         netConfig.wakuFlags,
                         netConfig.enrMultiaddrs)

proc getAutonatService*(rng = crypto.newRng()): AutonatService =
  ## AutonatService request other peers to dial us back
  ## flagging us as Reachable or NotReachable.
  ## minConfidence is used as threshold to determine the state.
  ## If maxQueueSize > numPeersToAsk past samples are considered
  ## in the calculation.
  let autonatService = AutonatService.new(
    autonatClient = AutonatClient.new(),
    rng = rng,
    scheduleInterval = some(chronos.seconds(120)),
    askNewConnectedPeers = false,
    numPeersToAsk = 3,
    maxQueueSize = 3,
    minConfidence = 0.7)

  proc statusAndConfidenceHandler(networkReachability: NetworkReachability, confidence: Option[float]) {.gcsafe, async.} =
    if confidence.isSome():
      info "Peer reachability status", networkReachability=networkReachability, confidence=confidence.get()

  autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

  return autonatService

## retain old signature, but deprecate it
proc new*(T: type WakuNode,
          nodeKey: crypto.PrivateKey,
          bindIp: ValidIpAddress,
          bindPort: Port,
          extIp = none(ValidIpAddress),
          extPort = none(Port),
          extMultiAddrs = newSeq[MultiAddress](),
          peerStorage: PeerStorage = nil,
          maxConnections = builders.MaxConnections,
          wsBindPort: Port = (Port)8000,
          wsEnabled: bool = false,
          wssEnabled: bool = false,
          secureKey: string = "",
          secureCert: string = "",
          wakuFlags = none(WakuEnrBitfield),
          nameResolver: NameResolver = nil,
          sendSignedPeerRecord = false,
          dns4DomainName = none(string),
          discv5UdpPort = none(Port),
          wakuDiscv5 = none(WakuDiscoveryV5),
          agentString = none(string),    # defaults to nim-libp2p version
          peerStoreCapacity = none(int), # defaults to 1.25 maxConnections
          # TODO: make this argument required after tests are updated
          rng: ref HmacDrbgContext = crypto.newRng()
          ): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError], deprecated: "Use NetConfig variant".} =
  let netConfig = NetConfig.init(
    bindIp = bindIp,
    bindPort = bindPort,
    extIp = extIp,
    extPort = extPort,
    extMultiAddrs = extMultiAddrs,
    wsBindPort = wsBindPort,
    wsEnabled = wsEnabled,
    wssEnabled = wssEnabled,
    wakuFlags = wakuFlags,
    dns4DomainName = dns4DomainName,
    discv5UdpPort = discv5UdpPort,
  )

  return WakuNode.new(
    nodeKey = nodeKey,
    netConfig = netConfig,
    peerStorage = peerStorage,
    maxConnections = maxConnections,
    secureKey = secureKey,
    secureCert = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    wakuDiscv5 = wakuDiscv5,
    agentString = agentString,
    peerStoreCapacity = peerStoreCapacity,
  )

proc new*(T: type WakuNode,
          nodeKey: crypto.PrivateKey,
          netConfig: NetConfig,
          peerStorage: PeerStorage = nil,
          maxConnections = builders.MaxConnections,
          secureKey: string = "",
          secureCert: string = "",
          nameResolver: NameResolver = nil,
          sendSignedPeerRecord = false,
          wakuDiscv5 = none(WakuDiscoveryV5),
          agentString = none(string),    # defaults to nim-libp2p version
          peerStoreCapacity = none(int), # defaults to 1.25 maxConnections
          # TODO: make this argument required after tests are updated
          rng: ref HmacDrbgContext = crypto.newRng()
          ): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  info "Initializing networking", addrs=netConfig.announcedAddresses

  let switch = newWakuSwitch(
    some(nodekey),
    address = netConfig.hostAddress,
    wsAddress = netConfig.wsHostAddress,
    transportFlags = {ServerFlags.ReuseAddr},
    rng = rng,
    maxConnections = maxConnections,
    wssEnabled = netConfig.wssEnabled,
    secureKeyPath = secureKey,
    secureCertPath = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    agentString = agentString,
    peerStoreCapacity = peerStoreCapacity,
    services = @[Service(getAutonatService(rng))],
  )

  return WakuNode(
    peerManager: PeerManager.new(switch, peerStorage),
    switch: switch,
    rng: rng,
    enr: netConfig.getEnr(wakuDiscv5, nodekey),
    announcedAddresses: netConfig.announcedAddresses,
    wakuDiscv5: if wakuDiscV5.isSome(): wakuDiscV5.get() else: nil,
  )

proc peerInfo*(node: WakuNode): PeerInfo =
  node.switch.peerInfo

proc peerId*(node: WakuNode): PeerId =
  node.peerInfo.peerId

# TODO: Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.

  let peerInfo = node.switch.peerInfo

  var listenStr : seq[string]
  for address in node.announcedAddresses:
    var fulladdr = $address & "/p2p/" & $peerInfo.peerId
    listenStr &= fulladdr
  let enrUri = node.enr.toUri()
  let wakuInfo = WakuInfo(listenAddresses: listenStr, enrUri: enrUri)
  return wakuInfo

proc connectToNodes*(node: WakuNode, nodes: seq[RemotePeerInfo] | seq[string], source = "api") {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  # NOTE This is dialing on WakuRelay protocol specifically
  await peer_manager.connectToNodes(node.peerManager, nodes, WakuRelayCodec, source=source)


## Waku relay

proc registerRelayDefaultHandler(node: WakuNode, topic: PubsubTopic) =
  if node.wakuRelay.isSubscribed(topic):
    return

  proc traceHandler(topic: PubsubTopic, data: seq[byte]) {.async, gcsafe.} =
    trace "waku.relay received",
      peerId=node.peerId,
      pubsubTopic=topic,
      hash=MultiHash.digest("sha2-256", data).expect("valid hash").data.buffer.to0xHex(), # TODO: this could be replaced by a message UID
      receivedTime=getNowInNanosecondTime()

    waku_node_messages.inc(labelValues = ["relay"])

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuFilter.isNil():
      return

    await node.wakuFilter.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuArchive.isNil():
      return

    node.wakuArchive.handleMessage(topic, msg)


  let defaultHandler = proc(topic: PubsubTopic, data: seq[byte]) {.async, gcsafe.} =
      let msg = WakuMessage.decode(data)
      if msg.isErr():
        return

      await traceHandler(topic, data)
      await filterHandler(topic, msg.value)
      await archiveHandler(topic, msg.value)

  node.wakuRelay.subscribe(topic, defaultHandler)


proc subscribe*(node: WakuNode, topic: PubsubTopic) =
  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return

  debug "subscribe", pubsubTopic= topic

  node.registerRelayDefaultHandler(topic)

proc subscribe*(node: WakuNode, topic: PubsubTopic, handler: WakuRelayHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return

  debug "subscribe", pubsubTopic= topic

  node.registerRelayDefaultHandler(topic)
  node.wakuRelay.subscribe(topic, handler)

proc unsubscribe*(node: WakuNode, topic: PubsubTopic, handler: WakuRelayHandler) =
  ## Unsubscribes a handler from a PubSub topic.
  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return

  debug "unsubscribe", oubsubTopic= topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribe(@[(topic, handler)])

proc unsubscribeAll*(node: WakuNode, topic: PubsubTopic) =
  ## Unsubscribes all handlers registered on a specific PubSub topic.

  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribeAll`. WakuRelay not mounted."
    return

  info "unsubscribeAll", topic=topic

  node.wakuRelay.unsubscribeAll(topic)


proc publish*(node: WakuNode, topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.

  if node.wakuRelay.isNil():
    error "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    # TODO: Improve error handling
    return

  discard await node.wakuRelay.publish(topic, message)

  trace "waku.relay published",
    peerId=node.peerId,
    pubsubTopic=topic,
    hash=MultiHash.digest("sha2-256", message.encode().buffer).expect("valid hash").data.buffer.to0xHex(), # TODO: this could be replaced by a message UID
    publishTime=getNowInNanosecondTime()

proc startRelay*(node: WakuNode) {.async.} =
  ## Setup and start relay protocol
  info "starting relay protocol"

  if node.wakuRelay.isNil():
    error "Failed to start relay. Not mounted."
    return

  ## Setup relay protocol

  # Resume previous relay connections
  if node.peerManager.peerStore.hasPeers(protocolMatcher(WakuRelayCodec)):
    info "Found previous WakuRelay peers. Reconnecting."

    # Reconnect to previous relay peers. This will respect a backoff period, if necessary
    let backoffPeriod = node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)

    await node.peerManager.reconnectPeers(WakuRelayCodec,
                                          backoffPeriod)

  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc mountRelay*(node: WakuNode,
                 topics: seq[string] = @[],
                 triggerSelf = true,
                 peerExchangeHandler = none(RoutingRecordsHandler)) {.async, gcsafe.} =
  ## The default relay topics is the union of all configured topics plus default PubsubTopic(s)
  info "mounting relay protocol"

  let initRes = WakuRelay.new(
    node.switch,
    triggerSelf = triggerSelf
  )
  if initRes.isErr():
    error "failed mountin relay protocol", error=initRes.error
    return

  node.wakuRelay = initRes.value

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    node.wakuRelay.parameters.enablePX = true # Feature flag for peer exchange in nim-libp2p
    node.wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  if node.started:
    await node.startRelay()

  node.switch.mount(node.wakuRelay, protocolMatcher(WakuRelayCodec))

  info "relay mounted successfully"

  # Subscribe to topics
  for topic in topics:
    node.subscribe(topic)


## Waku filter

proc mountFilter*(node: WakuNode, filterTimeout: Duration = WakuFilterTimeout) {.async, raises: [Defect, LPError]} =
  info "mounting filter protocol"
  node.wakuFilter = WakuFilter.new(node.peerManager, node.rng, filterTimeout)

  if node.started:
    await node.wakuFilter.start()

  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterCodec))

proc filterHandleMessage*(node: WakuNode, pubsubTopic: PubsubTopic, message: WakuMessage) {.async.}=
  if node.wakuFilter.isNil():
    error "cannot handle filter message", error="waku filter is nil"
    return

  await node.wakuFilter.handleMessage(pubsubTopic, message)


proc mountFilterClient*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting filter client"

  node.wakuFilterClient = WakuFilterClient.new(node.peerManager, node.rng)
  if node.started:
    # Node has started already. Let's start filter too.
    await node.wakuFilterClient.start()

  node.switch.mount(node.wakuFilterClient, protocolMatcher(WakuFilterCodec))

proc filterSubscribe*(node: WakuNode, pubsubTopic: PubsubTopic, contentTopics: ContentTopic|seq[ContentTopic],
                handler: FilterPushHandler, peer: RemotePeerInfo|string) {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if node.wakuFilterClient.isNil():
    error "cannot register filter subscription to topic", error="waku filter client is nil"
    return

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer

  info "registering filter subscription to content", pubsubTopic=pubsubTopic, contentTopics=contentTopics, peer=remotePeer

  # Add handler wrapper to store the message when pushed, when relay is disabled and filter enabled
  # TODO: Move this logic to wakunode2 app
  let handlerWrapper: FilterPushHandler = proc(pubsubTopic: string, message: WakuMessage) {.raises: [Exception].} =
      if node.wakuRelay.isNil() and not node.wakuStore.isNil():
        node.wakuArchive.handleMessage(pubSubTopic, message)

      handler(pubsubTopic, message)

  let subRes = await node.wakuFilterClient.subscribe(pubsubTopic, contentTopics, handlerWrapper, peer=remotePeer)
  if subRes.isOk():
    info "subscribed to topic", pubsubTopic=pubsubTopic, contentTopics=contentTopics
  else:
    error "failed filter subscription", error=subRes.error
    waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

proc filterUnsubscribe*(node: WakuNode, pubsubTopic: PubsubTopic, contentTopics: ContentTopic|seq[ContentTopic],
                  peer: RemotePeerInfo|string) {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Unsubscribe from a content filter.
  if node.wakuFilterClient.isNil():
    error "cannot unregister filter subscription to content", error="waku filter client is nil"
    return

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer

  info "deregistering filter subscription to content", pubsubTopic=pubsubTopic, contentTopics=contentTopics, peer=remotePeer

  let unsubRes = await node.wakuFilterClient.unsubscribe(pubsubTopic, contentTopics, peer=remotePeer)
  if unsubRes.isOk():
    info "unsubscribed from topic", pubsubTopic=pubsubTopic, contentTopics=contentTopics
  else:
    error "failed filter unsubscription", error=unsubRes.error
    waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

# TODO: Move to application module (e.g., wakunode2.nim)
proc subscribe*(node: WakuNode, pubsubTopic: PubsubTopic, contentTopics: ContentTopic|seq[ContentTopic], handler: FilterPushHandler) {.async, gcsafe,
  deprecated: "Use the explicit destination peer procedure. Use 'node.filterSubscribe()' instead.".} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if node.wakuFilterClient.isNil():
    error "cannot register filter subscription to topic", error="waku filter client is nil"
    return

  let peerOpt = node.peerManager.selectPeer(WakuFilterCodec)
  if peerOpt.isNone():
    error "cannot register filter subscription to topic", error="no suitable remote peers"
    return

  await node.filterSubscribe(pubsubTopic, contentTopics, handler, peer=peerOpt.get())

# TODO: Move to application module (e.g., wakunode2.nim)
proc unsubscribe*(node: WakuNode, pubsubTopic: PubsubTopic, contentTopics: ContentTopic|seq[ContentTopic]) {.async, gcsafe,
  deprecated: "Use the explicit destination peer procedure. Use 'node.filterUnsusbscribe()' instead.".} =
  ## Unsubscribe from a content filter.
  if node.wakuFilterClient.isNil():
    error "cannot unregister filter subscription to content", error="waku filter client is nil"
    return

  let peerOpt = node.peerManager.selectPeer(WakuFilterCodec)
  if peerOpt.isNone():
    error "cannot register filter subscription to topic", error="no suitable remote peers"
    return

  await node.filterUnsubscribe(pubsubTopic, contentTopics, peer=peerOpt.get())


## Waku swap

# NOTE: If using the swap protocol, it must be mounted before store. This is
# because store is using a reference to the swap protocol.
proc mountSwap*(node: WakuNode, swapConfig: SwapConfig = SwapConfig.init()) {.async, raises: [Defect, LPError].} =
  info "mounting swap", mode = $swapConfig.mode

  node.wakuSwap = WakuSwap.init(node.peerManager, node.rng, swapConfig)
  if node.started:
    # Node has started already. Let's start swap too.
    await node.wakuSwap.start()

  node.switch.mount(node.wakuSwap, protocolMatcher(WakuSwapCodec))


## Waku archive

proc mountArchive*(node: WakuNode,
                   driver: Option[ArchiveDriver],
                   messageValidator: Option[MessageValidator],
                   retentionPolicy: Option[RetentionPolicy]) =

  if driver.isNone():
    error "failed to mount waku archive protocol", error="archive driver not set"
    return

  node.wakuArchive = WakuArchive.new(driver.get(), messageValidator, retentionPolicy)

# TODO: Review this periodic task. Maybe, move it to the appplication code
const WakuArchiveDefaultRetentionPolicyInterval* = 30.minutes

proc executeMessageRetentionPolicy*(node: WakuNode) =
  if node.wakuArchive.isNil():
    return

  debug "executing message retention policy"

  node.wakuArchive.executeMessageRetentionPolicy()
  node.wakuArchive.reportStoredMessagesMetric()

proc startMessageRetentionPolicyPeriodicTask*(node: WakuNode, interval: Duration) =
  if node.wakuArchive.isNil():
    return

  # https://github.com/nim-lang/Nim/issues/17369
  var executeRetentionPolicy: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  executeRetentionPolicy = proc(udata: pointer) {.gcsafe.} =
    executeMessageRetentionPolicy(node)
    discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)

  discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)


## Waku store

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toArchiveQuery(request: HistoryQuery): ArchiveQuery =
  ArchiveQuery(
    pubsubTopic: request.pubsubTopic,
    contentTopics: request.contentTopics,
    cursor: request.cursor.map(proc(cursor: HistoryCursor): ArchiveCursor = ArchiveCursor(pubsubTopic: cursor.pubsubTopic, senderTime: cursor.senderTime, storeTime: cursor.storeTime, digest: cursor.digest)),
    startTime: request.startTime,
    endTime: request.endTime,
    pageSize: request.pageSize.uint,
    ascending: request.ascending
  )

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toHistoryResult*(res: ArchiveResult): HistoryResult =
  if res.isErr():
    let error = res.error
    case res.error.kind:
    of ArchiveErrorKind.DRIVER_ERROR, ArchiveErrorKind.INVALID_QUERY:
      err(HistoryError(
        kind: HistoryErrorKind.BAD_REQUEST,
        cause: res.error.cause
      ))
    else:
      err(HistoryError(kind: HistoryErrorKind.UNKNOWN))

  else:
    let response = res.get()
    ok(HistoryResponse(
      messages: response.messages,
      cursor: response.cursor.map(proc(cursor: ArchiveCursor): HistoryCursor = HistoryCursor(pubsubTopic: cursor.pubsubTopic, senderTime: cursor.senderTime, storeTime: cursor.storeTime, digest: cursor.digest)),
    ))

proc mountStore*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting waku store protocol"

  if node.wakuArchive.isNil():
    error "failed to mount waku store protocol", error="waku archive not set"
    return

  # TODO: Review this handler logic. Maybe, move it to the appplication code
  let queryHandler: HistoryQueryHandler = proc(request: HistoryQuery): HistoryResult =
      let request = request.toArchiveQuery()
      let response = node.wakuArchive.findMessages(request)
      response.toHistoryResult()

  node.wakuStore = WakuStore.new(node.peerManager, node.rng, queryHandler)


  if node.started:
    # Node has started already. Let's start store too.
    await node.wakuStore.start()

  node.switch.mount(node.wakuStore, protocolMatcher(WakuStoreCodec))


proc mountStoreClient*(node: WakuNode) =
  info "mounting store client"

  node.wakuStoreClient = WakuStoreClient.new(node.peerManager, node.rng)

proc query*(node: WakuNode, query: HistoryQuery, peer: RemotePeerInfo): Future[WakuStoreResult[HistoryResponse]] {.async, gcsafe.} =
  ## Queries known nodes for historical messages
  if node.wakuStoreClient.isNil():
    return err("waku store client is nil")

  let queryRes = await node.wakuStoreClient.query(query, peer)
  if queryRes.isErr():
    return err($queryRes.error)

  let response = queryRes.get()

  return ok(response)

# TODO: Move to application module (e.g., wakunode2.nim)
proc query*(node: WakuNode, query: HistoryQuery): Future[WakuStoreResult[HistoryResponse]] {.async, gcsafe,
  deprecated: "Use 'node.query()' with peer destination instead".} =
  ## Queries known nodes for historical messages
  if node.wakuStoreClient.isNil():
    return err("waku store client is nil")

  let peerOpt = node.peerManager.selectPeer(WakuStoreCodec)
  if peerOpt.isNone():
    error "no suitable remote peers"
    return err("peer_not_found_failure")

  return await node.query(query, peerOpt.get())

when defined(waku_exp_store_resume):
  # TODO: Move to application module (e.g., wakunode2.nim)
  proc resume*(node: WakuNode, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo])) {.async, gcsafe.} =
    ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online
    ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
    ## messages are stored in the the wakuStore's messages field and in the message db
    ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message
    ## an offset of 20 second is added to the time window to count for nodes asynchrony
    ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
    ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from.
    ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
    if node.wakuStoreClient.isNil():
      return

    let retrievedMessages = await node.wakuStoreClient.resume(peerList)
    if retrievedMessages.isErr():
      error "failed to resume store", error=retrievedMessages.error
      return

    info "the number of retrieved messages since the last online time: ", number=retrievedMessages.value


## Waku lightpush

proc mountLightPush*(node: WakuNode) {.async.} =
  info "mounting light push"

  var pushHandler: PushMessageHandler
  if node.wakuRelay.isNil():
    debug "mounting lightpush without relay (nil)"
    pushHandler = proc(peer: PeerId, pubsubTopic: string, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} =
      return err("no waku relay found")
  else:
    pushHandler = proc(peer: PeerId, pubsubTopic: string, message: WakuMessage): Future[WakuLightPushResult[void]] {.async.} =
      discard await node.wakuRelay.publish(pubsubTopic, message.encode().buffer)
      return ok()

  debug "mounting lightpush with relay"
  node.wakuLightPush = WakuLightPush.new(node.peerManager, node.rng, pushHandler)

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.wakuLightPush.start()

  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))


proc mountLightPushClient*(node: WakuNode) =
  info "mounting light push client"

  node.wakuLightpushClient = WakuLightPushClient.new(node.peerManager, node.rng)

proc lightpushPublish*(node: WakuNode, pubsubTopic: PubsubTopic, message: WakuMessage, peer: RemotePeerInfo): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  if node.wakuLightpushClient.isNil():
    return err("waku lightpush client is nil")

  debug "publishing message with lightpush", pubsubTopic=pubsubTopic, contentTopic=message.contentTopic, peer=peer

  return await node.wakuLightpushClient.publish(pubsubTopic, message, peer)

# TODO: Move to application module (e.g., wakunode2.nim)
proc lightpushPublish*(node: WakuNode, pubsubTopic: PubsubTopic, message: WakuMessage): Future[void] {.async, gcsafe,
  deprecated: "Use 'node.lightpushPublish()' instead".} =
  if node.wakuLightpushClient.isNil():
    error "failed to publish message", error="waku lightpush client is nil"
    return

  let peerOpt = node.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    error "failed to publish message", error="no suitable remote peers"
    return

  let publishRes = await node.lightpushPublish(pubsubTopic, message, peer=peerOpt.get())
  if publishRes.isOk():
    return

  error "failed to publish message", error=publishRes.error

## Waku RLN Relay
when defined(rln):
  proc mountRlnRelay*(node: WakuNode,
                      rlnConf: WakuRlnConfig,
                      spamHandler: Option[SpamHandler] = none(SpamHandler),
                      registrationHandler: Option[RegistrationHandler] = none(RegistrationHandler)) {.async.} =
    info "mounting rln relay"

    let rlnRelayRes = await WakuRlnRelay.new(node.wakuRelay,
                                             rlnConf,
                                             spamHandler,
                                             registrationHandler)
    if rlnRelayRes.isErr():
      error "failed to mount rln relay", error=rlnRelayRes.error
      return
    node.wakuRlnRelay = rlnRelayRes.get()


## Waku peer-exchange

proc mountPeerExchange*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting waku peer exchange"

  var discv5Opt: Option[WakuDiscoveryV5]
  if not node.wakuDiscV5.isNil():
    discv5Opt = some(node.wakuDiscV5)

  node.wakuPeerExchange = WakuPeerExchange.new(node.peerManager, discv5Opt)

  if node.started:
    await node.wakuPeerExchange.start()

  node.switch.mount(node.wakuPeerExchange, protocolMatcher(WakuPeerExchangeCodec))

proc fetchPeerExchangePeers*(node: Wakunode, amount: uint64) {.async, raises: [Defect].} =
  if node.wakuPeerExchange.isNil():
    error "could not get peers from px, waku peer-exchange is nil"
    return

  info "Retrieving peer info via peer exchange protocol"
  let pxPeersRes = await node.wakuPeerExchange.request(amount)
  if pxPeersRes.isOk:
    var validPeers = 0
    for pi in pxPeersRes.get().peerInfos:
      var record: enr.Record
      if enr.fromBytes(record, pi.enr):
        # TODO: Add source: PX
        node.peerManager.addPeer(record.toRemotePeerInfo().get)
        validPeers += 1
    info "Retrieved peer info via peer exchange protocol", validPeers = validPeers
  else:
    warn "Failed to retrieve peer info via peer exchange protocol", error = pxPeersRes.error

# TODO: Move to application module (e.g., wakunode2.nim)
proc setPeerExchangePeer*(node: WakuNode, peer: RemotePeerInfo|string) {.raises: [Defect, ValueError, LPError].} =
  if node.wakuPeerExchange.isNil():
    error "could not set peer, waku peer-exchange is nil"
    return

  info "Set peer-exchange peer", peer=peer

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer
  node.peerManager.addPeer(remotePeer, WakuPeerExchangeCodec)
  waku_px_peers.inc()


## Other protocols

proc mountLibp2pPing*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting libp2p ping protocol"

  try:
    node.libp2pPing = Ping.new(rng = node.rng)
  except Exception as e:
    # This is necessary as `Ping.new*` does not have explicit `raises` requirement
    # @TODO: remove exception handling once explicit `raises` in ping module
    raise newException(LPError, "Failed to initialize ping protocol")

  if node.started:
    # Node has started already. Let's start ping too.
    await node.libp2pPing.start()

  node.switch.mount(node.libp2pPing)

# TODO: Move this logic to PeerManager
proc keepaliveLoop(node: WakuNode, keepalive: chronos.Duration) {.async.} =
  while node.started:
    # Keep all connected peers alive while running
    trace "Running keepalive"

    # First get a list of connected peer infos
    let peers = node.peerManager.peerStore.peers()
                                .filterIt(it.connectedness == Connected)
                                .mapIt(it.toRemotePeerInfo())

    for peer in peers:
      try:
        let conn = await node.switch.dial(peer.peerId, peer.addrs, PingCodec)
        let pingDelay = await node.libp2pPing.ping(conn)
      except CatchableError as exc:
        waku_node_errors.inc(labelValues = ["keep_alive_failure"])

    await sleepAsync(keepalive)

proc startKeepalive*(node: WakuNode) =
  let defaultKeepalive = 2.minutes # 20% of the default chronosstream timeout duration

  info "starting keepalive", keepalive=defaultKeepalive

  asyncSpawn node.keepaliveLoop(defaultKeepalive)

proc runDiscv5Loop(node: WakuNode) {.async.} =
  ## Continuously add newly discovered nodes
  ## using Node Discovery v5
  if (node.wakuDiscv5.isNil):
    warn "Trying to run discovery v5 while it's disabled"
    return

  info "Starting discovery loop"

  while node.wakuDiscv5.listening:
    trace "Running discovery loop"
    let discoveredPeersRes = await node.wakuDiscv5.findRandomPeers()

    if discoveredPeersRes.isOk:
      let discoveredPeers = discoveredPeersRes.get
      let newSeen = discoveredPeers.countIt(not node.peerManager.peerStore[AddressBook].contains(it.peerId))
      info "Discovered peers", discovered=discoveredPeers.len, new=newSeen

      # Add all peers, new ones and already seen (in case their addresses changed)
      for peer in discoveredPeers:
        node.peerManager.addPeer(peer)

    # Discovery `queryRandom` can have a synchronous fast path for example
    # when no peers are in the routing table. Don't run it in continuous loop.
    #
    # Also, give some time to dial the discovered nodes and update stats etc
    await sleepAsync(5.seconds)

proc startDiscv5*(node: WakuNode): Future[bool] {.async.} =
  ## Start Discovery v5 service

  info "Starting discovery v5 service"

  if not node.wakuDiscv5.isNil():
    ## First start listening on configured port
    try:
      trace "Start listening on discv5 port"
      node.wakuDiscv5.open()
    except CatchableError:
      error "Failed to start discovery service. UDP port may be already in use"
      return false

    ## Start Discovery v5
    trace "Start discv5 service"
    node.wakuDiscv5.start()
    trace "Start discovering new peers using discv5"

    asyncSpawn node.runDiscv5Loop()

    debug "Successfully started discovery v5 service"
    info "Discv5: discoverable ENR ", enr = node.wakuDiscV5.protocol.localNode.record.toUri()
    return true

  return false

proc stopDiscv5*(node: WakuNode): Future[bool] {.async.} =
  ## Stop Discovery v5 service

  if not node.wakuDiscv5.isNil():
    info "Stopping discovery v5 service"

    ## Stop Discovery v5 process and close listening port
    if node.wakuDiscv5.listening:
      trace "Stop listening on discv5 port"
      await node.wakuDiscv5.closeWait()

    debug "Successfully stopped discovery v5 service"


proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.

  waku_version.set(1, labelValues=[git_version])
  info "Starting Waku node", version=git_version

  let peerInfo = node.switch.peerInfo
  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs
  var listenStr = ""
  for address in node.announcedAddresses:
    var fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]"
    listenStr &= fulladdr

  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr
  info "DNS: discoverable ENR ", enr = node.enr.toUri()

  # Perform relay-specific startup tasks TODO: this should be rethought
  if not node.wakuRelay.isNil():
    await node.startRelay()

  ## The switch uses this mapper to update peer info addrs
  ## with announced addrs after start
  let addressMapper =
    proc (listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
      return node.announcedAddresses
  node.switch.peerInfo.addressMappers.add(addressMapper)

  ## The switch will update addresses after start using the addressMapper
  await node.switch.start()

  node.started = true

  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil():
    await node.wakuRelay.stop()

  if not node.wakuDiscv5.isNil():
    discard await node.stopDiscv5()

  await node.switch.stop()
  node.peerManager.stop()

  node.started = false
