{.push raises: [Defect].}

import
  std/[hashes, options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/shims/net as stewNet,
  stew/byteutils,
  eth/keys,
  nimcrypto,
  bearssl/rand,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/[gossipsub, rpc/messages],
  libp2p/nameresolving/nameresolver,
  libp2p/[builders, multihash],
  libp2p/transports/[transport, tcptransport, wstransport]
import
  ../protocol/[waku_relay, waku_message],
  ../protocol/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter,
  ../protocol/waku_lightpush,
  ../protocol/waku_rln_relay/waku_rln_relay_types,
  ../protocol/waku_peer_exchange,
  ../utils/[peers, requests, wakuenr],
  ./peer_manager/peer_manager,
  ./storage/message/waku_store_queue,
  ./storage/message/message_retention_policy,
  ./storage/message/message_retention_policy_capacity,
  ./storage/message/message_retention_policy_time,
  ./dnsdisc/waku_dnsdisc,
  ./discv5/waku_discv5,
  ./wakuswitch

declarePublicGauge waku_version, "Waku version info (in git describe format)", ["version"]
declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicGauge waku_node_filters, "number of content filter subscriptions"
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]

logScope:
  topics = "wakunode"

# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# Default topic
const defaultTopic* = "/waku/2/default-waku/proto"

# Default Waku Filter Timeout
const WakuFilterTimeout: Duration = 1.days


# key and crypto modules different
type
  # XXX: Weird type, should probably be using pubsub PubsubTopic object name?
  PubsubTopic* = string
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
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    wakuSwap*: WakuSwap
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    wakuPeerExchange*: WakuPeerExchange
    enr*: enr.Record
    libp2pPing*: Ping
    filters*: Filters
    rng*: ref rand.HmacDrbgContext
    wakuDiscv5*: WakuDiscoveryV5
    announcedAddresses* : seq[MultiAddress]
    started*: bool # Indicates that node has started listening


proc protocolMatcher(codec: string): Matcher =
  ## Returns a protocol matcher function for the provided codec
  proc match(proto: string): bool {.gcsafe.} =
    ## Matches a proto with any postfix to the provided codec.
    ## E.g. if the codec is `/vac/waku/filter/2.0.0` it matches the protos:
    ## `/vac/waku/filter/2.0.0`, `/vac/waku/filter/2.0.0-beta3`, `/vac/waku/filter/2.0.0-actualnonsense`
    return proto.startsWith(codec)

  return match

proc updateSwitchPeerInfo(node: WakuNode) =
  ## TODO: remove this when supported upstream
  ## 
  ## nim-libp2p does not yet support announcing addrs
  ## different from bound addrs.
  ## 
  ## This is a temporary workaround to replace
  ## peer info addrs in switch to announced
  ## addresses.
  ## 
  ## WARNING: this should only be called once the switch
  ## has already been started.
  
  if node.announcedAddresses.len > 0:
    node.switch.peerInfo.addrs = node.announcedAddresses

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

proc new*(T: type WakuNode, 
          nodeKey: crypto.PrivateKey,
          bindIp: ValidIpAddress, 
          bindPort: Port,
          extIp = none(ValidIpAddress), 
          extPort = none(Port),
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
          discv5UdpPort = none(Port)): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  ## Initialize addresses
  let
    # Bind addresses
    hostAddress = ip4TcpEndPoint(bindIp, bindPort)
    wsHostAddress = if wsEnabled or wssEnabled: some(ip4TcpEndPoint(bindIp, wsbindPort) & wsFlag(wssEnabled))
                    else: none(MultiAddress)

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

  var announcedAddresses: seq[MultiAddress]
  if hostExtAddress.isSome():
    announcedAddresses.add(hostExtAddress.get())
  else:
    announcedAddresses.add(hostAddress) # We always have at least a bind address for the host
    
  if wsExtAddress.isSome():
    announcedAddresses.add(wsExtAddress.get())
  elif wsHostAddress.isSome():
    announcedAddresses.add(wsHostAddress.get())
  
  ## Initialize peer
  let
    rng = crypto.newRng()
    enrIp = if extIp.isSome(): extIp
            else: some(bindIp)
    enrTcpPort = if extPort.isSome(): extPort
                 else: some(bindPort)
    enrMultiaddrs = if wsExtAddress.isSome(): @[wsExtAddress.get()] # Only add ws/wss to `multiaddrs` field
                    elif wsHostAddress.isSome(): @[wsHostAddress.get()]
                    else: @[]
    enr = initEnr(nodeKey,
                  enrIp,
                  enrTcpPort,
                  discv5UdpPort,
                  wakuFlags,
                  enrMultiaddrs)
  
  info "Initializing networking", addrs=announcedAddresses

  let switch = newWakuSwitch(
    some(nodekey),
    hostAddress,
    wsHostAddress,
    transportFlags = {ServerFlags.ReuseAddr},
    rng = rng, 
    maxConnections = maxConnections,
    wssEnabled = wssEnabled,
    secureKeyPath = secureKey,
    secureCertPath = secureCert,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord
  )
  
  let wakuNode = WakuNode(
    peerManager: PeerManager.new(switch, peerStorage),
    switch: switch,
    rng: rng,
    enr: enr,
    filters: Filters.init(),
    announcedAddresses: announcedAddresses
  )

  return wakuNode


proc peerInfo*(node: WakuNode): PeerInfo = 
  node.switch.peerInfo

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
  await connectToNodes(node.peerManager, nodes, WakuRelayCodec, source)


## Waku relay

proc subscribe(node: WakuNode, topic: PubsubTopic, handler: Option[TopicHandler]) =
  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    # TODO: improved error handling
    return

  info "subscribe", topic=topic

  proc defaultHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    # A default handler should be registered for all topics
    trace "Hit default handler", topic=topic, data=data

    let msg = WakuMessage.init(data)
    if msg.isErr():
      # TODO: Add metric to track waku message decode errors
      return


    # Notify mounted protocols of new message
    if not node.wakuFilter.isNil():
      await node.wakuFilter.handleMessage(topic, msg.value)
    
    if not node.wakuStore.isNil():
      node.wakuStore.handleMessage(topic, msg.value)

    waku_node_messages.inc(labelValues = ["relay"])


  let wakuRelay = node.wakuRelay

  if topic notin PubSub(wakuRelay).topics:
    # Add default handler only for new topics
    debug "Registering default handler", topic=topic
    wakuRelay.subscribe(topic, defaultHandler)

  if handler.isSome():
    debug "Registering handler", topic=topic
    wakuRelay.subscribe(topic, handler.get())

proc subscribe*(node: WakuNode, topic: PubsubTopic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  node.subscribe(topic, some(handler))

proc unsubscribe*(node: WakuNode, topic: PubsubTopic, handler: TopicHandler) =
  ## Unsubscribes a handler from a PubSub topic.
  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    # TODO: improved error handling
    return
  
  info "unsubscribe", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribe(@[(topic, handler)])

proc unsubscribeAll*(node: WakuNode, topic: PubsubTopic) =
  ## Unsubscribes all handlers registered on a specific PubSub topic.
  
  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribeAll`. WakuRelay not mounted."
    # TODO: improved error handling
    return
  
  info "unsubscribeAll", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribeAll(topic)
  
proc publish*(node: WakuNode, topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
    
  if node.wakuRelay.isNil():
    error "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    # TODO: Improve error handling
    return

  trace "publish", topic=topic, contentTopic=message.contentTopic

  let data = message.encode().buffer
  discard await node.wakuRelay.publish(topic, data)

proc startRelay*(node: WakuNode) {.async.} =
  if node.wakuRelay.isNil():
    trace "Failed to start relay. Not mounted."
    return

  ## Setup and start relay protocol
  info "starting relay"
  
  # PubsubTopic subscriptions
  for topic in node.wakuRelay.defaultTopics:
    node.subscribe(topic, none(TopicHandler))

  # Resume previous relay connections
  if node.peerManager.hasPeers(protocolMatcher(WakuRelayCodec)):
    info "Found previous WakuRelay peers. Reconnecting."
    
    # Reconnect to previous relay peers. This will respect a backoff period, if necessary
    let backoffPeriod = node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)

    await node.peerManager.reconnectPeers(WakuRelayCodec,
                                          protocolMatcher(WakuRelayCodec),
                                          backoffPeriod)
  
  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc mountRelay*(node: WakuNode,
                 topics: seq[string] = newSeq[string](),
                 triggerSelf = true,
                 peerExchangeHandler = none(RoutingRecordsHandler))
  # TODO: Better error handling: CatchableError is raised by `waitFor`
  {.async, gcsafe, raises: [Defect, InitializationError, LPError, CatchableError].} =

  proc msgIdProvider(m: messages.Message): Result[MessageID, ValidationResult] =
    let mh = MultiHash.digest("sha2-256", m.data)
    if mh.isOk():
      return ok(mh[].data.buffer)
    else:
      return ok(($m.data.hash).toBytes())

  let wakuRelay = WakuRelay.init(
    switch = node.switch,
    msgIdProvider = msgIdProvider,
    triggerSelf = triggerSelf,
    sign = false,
    verifySignature = false,
    maxMessageSize = MaxWakuMessageSize
  )
  
  info "mounting relay"

  ## The default relay topics is the union of
  ## all configured topics plus the hard-coded defaultTopic(s)
  wakuRelay.defaultTopics = concat(@[defaultTopic], topics)

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    wakuRelay.parameters.enablePX = true # Feature flag for peer exchange in nim-libp2p
    wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  node.wakuRelay = wakuRelay
  if node.started:
    # Node has started already. Let's start relay too.
    await node.startRelay()

  node.switch.mount(wakuRelay, protocolMatcher(WakuRelayCodec))    
        
  info "relay mounted successfully"


## Waku filter

proc mountFilter*(node: WakuNode, filterTimeout: Duration = WakuFilterTimeout) {.async, raises: [Defect, LPError]} =
  info "mounting filter"
  proc filterHandler(requestId: string, msg: MessagePush) {.async, gcsafe.} =
    
    info "push received"
    for message in msg.messages:
      node.filters.notify(message, requestId) # Trigger filter handlers on a light node

      if not node.wakuStore.isNil and (requestId in node.filters):
        let pubSubTopic = node.filters[requestId].pubSubTopic
        node.wakuStore.handleMessage(pubSubTopic, message)

      waku_node_messages.inc(labelValues = ["filter"])

  node.wakuFilter = WakuFilter.init(node.peerManager, node.rng, filterHandler, filterTimeout)
  if node.started:
    # Node has started already. Let's start filter too.
    await node.wakuFilter.start()

  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterCodec))

proc setFilterPeer*(node: WakuNode, peer: RemotePeerInfo|string) {.raises: [Defect, ValueError, LPError].} =
  if node.wakuFilter.isNil():
    error "could not set peer, waku filter is nil"
    return

  info "Set filter peer", peer=peer

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer
  node.wakuFilter.setPeer(remotePeer)

proc subscribe*(node: WakuNode, request: FilterRequest, handler: ContentFilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  
  # Sanity check for well-formed subscribe FilterRequest
  doAssert(request.subscribe, "invalid subscribe request")
  
  info "subscribe content", filter=request

  var id = generateRequestId(node.rng)

  if not node.wakuFilter.isNil():
    let
      pubsubTopic = request.pubsubTopic
      contentTopics = request.contentFilters.mapIt(it.contentTopic)

    let resSubscription = await node.wakuFilter.subscribe(pubsubTopic, contentTopics)
    if resSubscription.isOk():
      id = resSubscription.get()
    else:
      # Failed to subscribe
      error "remote subscription to filter failed", filter = request
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

  # Register handler for filter, whether remote subscription succeeded or not
  node.filters.addContentFilters(id, request.pubSubTopic, request.contentFilters, handler)
  waku_node_filters.set(node.filters.len.int64)

proc unsubscribe*(node: WakuNode, request: FilterRequest) {.async, gcsafe.} =
  ## Unsubscribe from a content filter.
  
  # Sanity check for well-formed unsubscribe FilterRequest
  doAssert(request.subscribe == false, "invalid unsubscribe request")
  
  info "unsubscribe content", filter=request
  
  let 
    pubsubTopic = request.pubsubTopic
    contentTopics = request.contentFilters.mapIt(it.contentTopic)
  discard await node.wakuFilter.unsubscribe(pubsubTopic, contentTopics)
  node.filters.removeContentFilters(request.contentFilters)

  waku_node_filters.set(node.filters.len.int64)


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


## Waku store

const MessageStoreDefaultRetentionPolicyInterval* = 30.minutes

proc executeMessageRetentionPolicy*(node: WakuNode) =
  if node.wakuStore.isNil():
    return

  if node.wakuStore.store.isNil():
    return

  debug "executing message retention policy"

  node.wakuStore.executeMessageRetentionPolicy()
  node.wakuStore.reportStoredMessagesMetric()

proc startMessageRetentionPolicyPeriodicTask*(node: WakuNode, interval: Duration) =
  if node.wakuStore.isNil():
    return

  if node.wakuStore.store.isNil():
    return

  # https://github.com/nim-lang/Nim/issues/17369
  var executeRetentionPolicy: proc(udata: pointer) {.gcsafe, raises: [Defect].}
  executeRetentionPolicy = proc(udata: pointer) {.gcsafe.} = 
    executeMessageRetentionPolicy(node)
    discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)
  
  discard setTimer(Moment.fromNow(interval), executeRetentionPolicy)

proc mountStore*(node: WakuNode, store: MessageStore = nil, retentionPolicy=none(MessageRetentionPolicy) ) {.async, raises: [Defect, LPError].} =
  if node.wakuSwap.isNil():
    info "mounting waku store protocol (no waku swap)"
  else:
    info "mounting waku store protocol with waku swap support"

  node.wakuStore = WakuStore.init(
    node.peerManager, 
    node.rng, 
    store, 
    wakuSwap=node.wakuSwap, 
    retentionPolicy=retentionPolicy
  )

  if node.started:
    # Node has started already. Let's start store too.
    await node.wakuStore.start()

  node.switch.mount(node.wakuStore, protocolMatcher(WakuStoreCodec))

proc setStorePeer*(node: WakuNode, peer: RemotePeerInfo|string) {.raises: [Defect, ValueError, LPError].} =
  if node.wakuStore.isNil():
    error "could not set peer, waku store is nil"
    return

  info "Set store peer", peer=peer

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer
  node.wakuStore.setPeer(remotePeer)

proc query*(node: WakuNode, query: HistoryQuery): Future[WakuStoreResult[HistoryResponse]] {.async, gcsafe.} = 
  ## Queries known nodes for historical messages

  # TODO: Once waku swap is less experimental, this can simplified
  if node.wakuSwap.isNil():
    debug "Using default query"
    return await node.wakuStore.query(query)
  else:
    debug "Using SWAP accounting query"
    # TODO: wakuSwap now part of wakuStore object
    return await node.wakuStore.queryWithAccounting(query)

proc resume*(node: WakuNode, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo])) {.async, gcsafe.} =
  ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online 
  ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
  ## messages are stored in the the wakuStore's messages field and in the message db
  ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message 
  ## an offset of 20 second is added to the time window to count for nodes asynchrony
  ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
  ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from. 
  ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
  if node.wakuStore.isNil():
    return

  let retrievedMessages = await node.wakuStore.resume(peerList)
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
    # TODO: Remove after using waku lightpush client
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

proc setLightPushPeer*(node: WakuNode, peer: RemotePeerInfo|string) {.raises: [Defect, ValueError, LPError].} =
  if node.wakuLightPush.isNil():
    error "could not set peer, waku lightpush is nil"
    return

  info "Set lightpush peer", peer=peer

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer
  node.wakuLightPush.setPeer(remotePeer)

proc lightpush*(node: WakuNode, topic: PubsubTopic, message: WakuMessage): Future[WakuLightpushResult[PushResponse]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  debug "Publishing with lightpush", topic=topic, contentTopic=message.contentTopic

  let rpc = PushRequest(pubSubTopic: topic, message: message)
  return await node.wakuLightPush.request(rpc)

proc lightpush2*(node: WakuNode, topic: PubsubTopic, message: WakuMessage) {.async, gcsafe.} =
  discard await node.lightpush(topic, message)


## Waku peer-exchange

proc mountWakuPeerExchange*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting waku peer exchange"

  var discv5Opt: Option[WakuDiscoveryV5]
  if not node.wakuDiscV5.isNil():
    discv5Opt = some(node.wakuDiscV5)
  node.wakuPeerExchange = WakuPeerExchange.init(node.peerManager, discv5Opt)

  if node.started:
    # Node has started already. Let's start Waku peer exchange too.
    await node.wakuPeerExchange.start()

  node.switch.mount(node.wakuPeerExchange, protocolMatcher(WakuPeerExchangeCodec))

proc setPeerExchangePeer*(node: WakuNode, peer: RemotePeerInfo|string) {.raises: [Defect, ValueError, LPError].} =
  if node.wakuPeerExchange.isNil():
    error "could not set peer, waku peer-exchange is nil"
    return

  info "Set peer-exchange peer", peer=peer

  let remotePeer = when peer is string: parseRemotePeerInfo(peer)
                   else: peer
  node.wakuPeerExchange.setPeer(remotePeer)


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

proc keepaliveLoop(node: WakuNode, keepalive: chronos.Duration) {.async.} =
  while node.started:
    # Keep all connected peers alive while running
    trace "Running keepalive"

    # First get a list of connected peer infos
    let peers = node.peerManager.peers()
                                .filterIt(node.peerManager.connectedness(it.peerId) == Connected)
                                .mapIt(it.toRemotePeerInfo())

    # Attempt to retrieve and ping the active outgoing connection for each peer
    for peer in peers:
      let connOpt = await node.peerManager.dialPeer(peer, PingCodec)

      if connOpt.isNone():
        # TODO: more sophisticated error handling here
        debug "failed to connect to remote peer", peer=peer
        waku_node_errors.inc(labelValues = ["keep_alive_failure"])
        return

      discard await node.libp2pPing.ping(connOpt.get())  # Ping connection
    
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
    ## Query for a random target and collect all discovered nodes
    ## TODO: we could filter nodes here
    let discoveredPeers = await node.wakuDiscv5.findRandomPeers()
    if discoveredPeers.isOk():
      ## Let's attempt to connect to peers we
      ## have not encountered before
      
      trace "Discovered peers", count=discoveredPeers.get().len()

      let newPeers = discoveredPeers.get().filterIt(
        not node.switch.isConnected(it.peerId))

      if newPeers.len > 0:
        debug "Connecting to newly discovered peers", count=newPeers.len()
        await node.connectToNodes(newPeers, "discv5")

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
  
  ## NB: careful when moving this. We need to start the switch with the bind address
  ## BEFORE updating with announced addresses for the sake of identify.
  await node.switch.start()
  
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
  
  ## Update switch peer info with announced addrs
  node.updateSwitchPeerInfo()

  node.started = true
  
  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil():
    await node.wakuRelay.stop()
  
  if not node.wakuDiscv5.isNil():
    discard await node.stopDiscv5()

  await node.switch.stop()

  node.started = false