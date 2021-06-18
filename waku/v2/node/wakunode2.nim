import
  std/[options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  metrics/chronos_httpserver,
  stew/shims/net as stewNet,
  # TODO: Why do we need eth keys?
  eth/keys,
  web3,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protocols/ping,
  # NOTE For TopicHandler, solve with exports?
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/builders,
  ../protocol/[waku_relay, waku_message, message_notifier],
  ../protocol/waku_store/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter/waku_filter,
  ../protocol/waku_lightpush/waku_lightpush,
  ../protocol/waku_rln_relay/waku_rln_relay_types,
  ../utils/peers,
  ./storage/message/message_store,
  ./storage/peer/peer_storage,
  ../utils/requests,
  ./peer_manager/peer_manager

when defined(rln):
  import ../protocol/waku_rln_relay/[rln, waku_rln_relay_utils]

declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicGauge waku_node_filters, "number of content filter subscriptions"
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]

logScope:
  topics = "wakunode"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# Default topic
const defaultTopic = "/waku/2/default-waku/proto"

# key and crypto modules different
type
  KeyPair* = crypto.KeyPair
  PublicKey* = crypto.PublicKey
  PrivateKey* = crypto.PrivateKey

  # XXX: Weird type, should probably be using pubsub Topic object name?
  Topic* = string
  Message* = seq[byte]

  WakuInfo* = object
    # NOTE One for simplicity, can extend later as needed
    listenStr*: string
    #multiaddrStrings*: seq[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuStore*: WakuStore
    wakuFilter*: WakuFilter
    wakuSwap*: WakuSwap
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    peerInfo*: PeerInfo
    libp2pPing*: Ping
    libp2pTransportLoops*: seq[Future[void]]
  # TODO Revist messages field indexing as well as if this should be Message or WakuMessage
    messages*: seq[(Topic, WakuMessage)]
    filters*: Filters
    subscriptions*: MessageNotificationSubscriptions
    rng*: ref BrHmacDrbgContext
    started*: bool # Indicates that node has started listening

# NOTE Any difference here in Waku vs Eth2?
# E.g. Devp2p/Libp2p support, etc.
#func asLibp2pKey*(key: keys.PublicKey): PublicKey =
#  PublicKey(scheme: Secp256k1, skkey: secp.SkPublicKey(key))

func asEthKey*(key: PrivateKey): keys.PrivateKey =
  keys.PrivateKey(key.skkey)

proc removeContentFilters(filters: var Filters, contentFilters: seq[ContentFilter]) {.gcsafe.} =
  # Flatten all unsubscribe topics into single seq
  let unsubscribeTopics = contentFilters.mapIt(it.contentTopic)
  
  debug "unsubscribing", unsubscribeTopics=unsubscribeTopics

  var rIdToRemove: seq[string] = @[]
  for rId, f in filters.mpairs:
    # Iterate filter entries to remove matching content topics
  
    # make sure we delete the content filter
    # if no more topics are left
    f.contentFilters.keepIf(proc (cf: auto): bool = cf.contentTopic notin unsubscribeTopics)

    if f.contentFilters.len == 0:
      rIdToRemove.add(rId)

  # make sure we delete the filter entry
  # if no more content filters left
  for rId in rIdToRemove:
    filters.del(rId)
  
  debug "filters modified", filters=filters

template tcpEndPoint(address, port): auto =
  MultiAddress.init(address, tcpProtocol, port)

## Public API
##

proc init*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port](),
    peerStorage: PeerStorage = nil): T =
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
  peerInfo.addrs.add(hostAddress) # Index 0
  for multiaddr in announcedAddresses:
    peerInfo.addrs.add(multiaddr) # Announced addresses in index > 0
  
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
    peerManager: PeerManager.new(switch, peerStorage),
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
  let listenStr = $peerInfo.addrs[^1] & "/p2p/" & $peerInfo.peerId
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

  if not node.wakuRelay.isNil:
    await node.wakuRelay.start()
  
  node.started = true

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil:
    await node.wakuRelay.stop()

  await node.switch.stop()

  node.started = false

proc subscribe(node: WakuNode, topic: Topic, handler: Option[TopicHandler]) =
  if node.wakuRelay.isNil:
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    # @TODO improved error handling
    return

  info "subscribe", topic=topic

  proc defaultHandler(topic: string, data: seq[byte]) {.async, gcsafe.} =
    # A default handler should be registered for all topics
    trace "Hit default handler", topic=topic, data=data

    let msg = WakuMessage.init(data)
    if msg.isOk():
      await node.subscriptions.notify(topic, msg.value()) # Trigger subscription handlers on a store/filter node
      waku_node_messages.inc(labelValues = ["relay"])

  let wakuRelay = node.wakuRelay

  if topic notin PubSub(wakuRelay).topics:
    # Add default handler only for new topics
    debug "Registering default handler", topic=topic
    wakuRelay.subscribe(topic, defaultHandler)

  if handler.isSome:
    debug "Registering handler", topic=topic
    wakuRelay.subscribe(topic, handler.get())

proc subscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Subscribes to a PubSub topic. Triggers handler when receiving messages on
  ## this topic. TopicHandler is a method that takes a topic and some data.
  ##
  ## NOTE The data field SHOULD be decoded as a WakuMessage.
  ## Status: Implemented.
  node.subscribe(topic, some(handler))

proc subscribe*(node: WakuNode, request: FilterRequest, handler: ContentFilterHandler) {.async, gcsafe.} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  ## FilterHandler is a method that takes a MessagePush.
  ##
  ## Status: Implemented.
  
  # Sanity check for well-formed subscribe FilterRequest
  doAssert(request.subscribe, "invalid subscribe request")
  
  info "subscribe content", filter=request

  var id = generateRequestId(node.rng)

  if node.wakuFilter.isNil == false:
    let idOpt = await node.wakuFilter.subscribe(request)

    if idOpt.isSome():
      # Subscribed successfully.
      id = idOpt.get()
    else:
      # Failed to subscribe
      error "remote subscription to filter failed", filter = request
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

  # Register handler for filter, whether remote subscription succeeded or not
  node.filters[id] = Filter(contentFilters: request.contentFilters, handler: handler)
  waku_node_filters.set(node.filters.len.int64)

proc unsubscribe*(node: WakuNode, topic: Topic, handler: TopicHandler) =
  ## Unsubscribes a handler from a PubSub topic.
  ##
  ## Status: Implemented.
  if node.wakuRelay.isNil:
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    # @TODO improved error handling
    return
  
  info "unsubscribe", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribe(@[(topic, handler)])

proc unsubscribeAll*(node: WakuNode, topic: Topic) =
  ## Unsubscribes all handlers registered on a specific PubSub topic.
  ##
  ## Status: Implemented.
  
  if node.wakuRelay.isNil:
    error "Invalid API call to `unsubscribeAll`. WakuRelay not mounted."
    # @TODO improved error handling
    return
  
  info "unsubscribeAll", topic=topic

  let wakuRelay = node.wakuRelay
  wakuRelay.unsubscribeAll(topic)
  

proc unsubscribe*(node: WakuNode, request: FilterRequest) {.async, gcsafe.} =
  ## Unsubscribe from a content filter.
  ##
  ## Status: Implemented.
  
  # Sanity check for well-formed unsubscribe FilterRequest
  doAssert(request.subscribe == false, "invalid unsubscribe request")
  
  info "unsubscribe content", filter=request
  
  await node.wakuFilter.unsubscribe(request)
  node.filters.removeContentFilters(request.contentFilters)

  waku_node_filters.set(node.filters.len.int64)


proc publish*(node: WakuNode, topic: Topic, message: WakuMessage,  rlnRelayEnabled: bool = false) {.async, gcsafe.} =
  ## Publish a `WakuMessage` to a PubSub topic. `WakuMessage` should contain a
  ## `contentTopic` field for light node functionality. This field may be also
  ## be omitted.
  ##
  ## Status: Implemented.
  ## When rlnRelayEnabled is true, a zkp will be generated and attached to the message (it is an experimental feature)
  
  if node.wakuRelay.isNil:
    error "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    # @TODO improved error handling
    return

  let wakuRelay = node.wakuRelay
  debug "publish", topic=topic, contentTopic=message.contentTopic
  var publishingMessage = message

  when defined(rln):
    if rlnRelayEnabled:
      # if rln relay is enabled then a proof must be generated and added to the waku message
      let 
        proof = proofGen(message.payload)
        ## TODO here  since the message is immutable we have to make a copy of it and then attach the proof to its duplicate 
        ## TODO however, it might be better to change message type to mutable (i.e., var) so that we can add the proof field to the original message
        publishingMessage = WakuMessage(payload: message.payload, contentTopic: message.contentTopic, version: message.version, proof: proof)

  let data = message.encode().buffer

  discard await wakuRelay.publish(topic, data)

proc lightpush*(node: WakuNode, topic: Topic, message: WakuMessage, handler: PushResponseHandler) {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not in `handler`.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality. This field may be also be omitted.
  ##
  ## Status: Implemented.

  debug "Publishing with lightpush", topic=topic, contentTopic=message.contentTopic

  let rpc = PushRequest(pubSubTopic: topic, message: message)
  await node.wakuLightPush.request(rpc, handler)

proc query*(node: WakuNode, query: HistoryQuery, handler: QueryHandlerFunc) {.async, gcsafe.} =
  ## Queries known nodes for historical messages. Triggers the handler whenever a response is received.
  ## QueryHandlerFunc is a method that takes a HistoryResponse.
  ##
  ## Status: Implemented.

  # TODO Once waku swap is less experimental, this can simplified
  if node.wakuSwap.isNil:
    debug "Using default query"
    await node.wakuStore.query(query, handler)
  else:
    debug "Using SWAPAccounting query"
    # TODO wakuSwap now part of wakuStore object
    await node.wakuStore.queryWithAccounting(query, handler)

proc resume*(node: WakuNode, peerList: Option[seq[PeerInfo]] = none(seq[PeerInfo])) {.async, gcsafe.} =
  ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online 
  ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
  ## messages are stored in the the wakuStore's messages field and in the message db
  ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message 
  ## an offset of 20 second is added to the time window to count for nodes asynchrony
  ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
  ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from. 
  ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
  
  if not node.wakuStore.isNil:
    let retrievedMessages = await node.wakuStore.resume(peerList)
    if retrievedMessages.isOk:
      info "the number of retrieved messages since the last online time: ", number=retrievedMessages.value


# TODO Extend with more relevant info: topics, peers, memory usage, online time, etc
proc info*(node: WakuNode): WakuInfo =
  ## Returns information about the Node, such as what multiaddress it can be reached at.
  ##
  ## Status: Implemented.
  ##

  # TODO Generalize this for other type of multiaddresses
  let peerInfo = node.peerInfo
  let listenStr = $peerInfo.addrs[^1] & "/p2p/" & $peerInfo.peerId
  let wakuInfo = WakuInfo(listenStr: listenStr)
  return wakuInfo

proc mountFilter*(node: WakuNode) =
  info "mounting filter"
  proc filterHandler(requestId: string, msg: MessagePush) {.gcsafe.} =
    info "push received"
    for message in msg.messages:
      node.filters.notify(message, requestId) # Trigger filter handlers on a light node
      waku_node_messages.inc(labelValues = ["filter"])

  node.wakuFilter = WakuFilter.init(node.peerManager, node.rng, filterHandler)
  node.switch.mount(node.wakuFilter)
  node.subscriptions.subscribe(WakuFilterCodec, node.wakuFilter.subscription())

# NOTE: If using the swap protocol, it must be mounted before store. This is
# because store is using a reference to the swap protocol.
proc mountSwap*(node: WakuNode, swapConfig: SwapConfig = SwapConfig.init()) =
  info "mounting swap", mode = $swapConfig.mode
  node.wakuSwap = WakuSwap.init(node.peerManager, node.rng, swapConfig)
  node.switch.mount(node.wakuSwap)
  # NYI - Do we need this?
  #node.subscriptions.subscribe(WakuSwapCodec, node.wakuSwap.subscription())

proc mountStore*(node: WakuNode, store: MessageStore = nil, persistMessages: bool = false) =
  info "mounting store"

  if node.wakuSwap.isNil:
    debug "mounting store without swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store)
  else:
    debug "mounting store with swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store, node.wakuSwap)

  node.switch.mount(node.wakuStore)
  if persistMessages:
    node.subscriptions.subscribe(WakuStoreCodec, node.wakuStore.subscription())

when defined(rln):
  proc mountRlnRelay*(node: WakuNode, ethClientAddress: Option[string] = none(string), ethAccountAddress: Option[Address] = none(Address), membershipContractAddress:  Option[Address] = none(Address)) {.async.} =
    # TODO return a bool value to indicate the success of the call
    # check whether inputs are provided
    doAssert(ethClientAddress.isSome())
    doAssert(ethAccountAddress.isSome())
    doAssert(membershipContractAddress.isSome())

    # create an RLN instance
    var 
      ctx = RLN[Bn256]()
      ctxPtr = addr(ctx)
    doAssert(createRLNInstance(32, ctxPtr))

    # generate the membership keys
    let membershipKeyPair = membershipKeyGen(ctxPtr)
    # check whether keys are generated
    doAssert(membershipKeyPair.isSome())
    debug "the membership key for the rln relay is generated"

    # initialize the WakuRLNRelay
    var rlnPeer = WakuRLNRelay(membershipKeyPair: membershipKeyPair.get(),
      ethClientAddress: ethClientAddress.get(),
      ethAccountAddress: ethAccountAddress.get(),
      membershipContractAddress: membershipContractAddress.get())
    
    # register the rln-relay peer to the membership contract
    let is_successful = await rlnPeer.register()
    # check whether registration is done
    doAssert(is_successful)
    debug "peer is successfully registered into the membership contract"

    node.wakuRlnRelay = rlnPeer

when defined(rln):
  proc addRLNRelayValidator*(node: WakuNode, pubsubTopic: string) =
    ## this procedure is a thin wrapper for the pubsub addValidator method
    ## it sets message validator on the given pubsubTopic, the validator will check that
    ## all the messages published in the pubsubTopic have a valid zero-knowledge proof 
    proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
      let msg = WakuMessage.init(message.data) 
      if msg.isOk():
        #  check the proof
        if proofVrfy(msg.value().payload, msg.value().proof):
          result = ValidationResult.Accept
    # set a validator for the pubsubTopic 
    let pb  = PubSub(node.wakuRelay)
    pb.addValidator(pubsubTopic, validator)

proc mountRelay*(node: WakuNode,
                 topics: seq[string] = newSeq[string](),
                 rlnRelayEnabled = false,
                 relayMessages = true,
                 triggerSelf = true) {.gcsafe.} =
  let wakuRelay = WakuRelay.init(
    switch = node.switch,
    # Use default
    #msgIdProvider = msgIdProvider,
    triggerSelf = triggerSelf,
    sign = false,
    verifySignature = false
  )
  
  info "mounting relay", rlnRelayEnabled=rlnRelayEnabled, relayMessages=relayMessages

  node.switch.mount(wakuRelay)

  if not relayMessages:
    ## Some nodes may choose not to have the capability to relay messages (e.g. "light" nodes).
    ## All nodes, however, currently require WakuRelay, regardless of desired capabilities.
    ## This is to allow protocol stream negotation with relay-capable nodes to succeed.
    ## Here we mount relay on the switch only, but do not proceed to subscribe to any pubsub
    ## topics. We also never start the relay protocol. node.wakuRelay remains nil.
    ## @TODO: in future, this WakuRelay dependency will be removed completely
    return

  node.wakuRelay = wakuRelay

  node.subscribe(defaultTopic, none(TopicHandler))

  for topic in topics:
    node.subscribe(topic, none(TopicHandler))

  if node.peerManager.hasPeers(WakuRelayCodec):
    trace "Found previous WakuRelay peers. Reconnecting."
    # Reconnect to previous relay peers. This will respect a backoff period, if necessary
    waitFor node.peerManager.reconnectPeers(WakuRelayCodec,
                                            wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime))
  when defined(rln):
    if rlnRelayEnabled:
      # TODO pass rln relay inputs to this proc, right now it uses default values that are set in the mountRlnRelay proc
      info "WakuRLNRelay is enabled"
      waitFor mountRlnRelay(node)
      # TODO currently the message validator is set for the defaultTopic, this can be configurable to accept other pubsub topics as well 
      addRLNRelayValidator(node, defaultTopic)
      info "WakuRLNRelay is mounted successfully"
  
  if node.started:
    # Node has already started. Start the WakuRelay protocol

    waitFor node.wakuRelay.start()

    info "relay mounted and started successfully"

proc mountLightPush*(node: WakuNode) =
  info "mounting light push"

  if node.wakuRelay.isNil:
    debug "mounting lightpush without relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil)
  else:
    debug "mounting lightpush with relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil, node.wakuRelay)

  node.switch.mount(node.wakuLightPush)

proc mountLibp2pPing*(node: WakuNode) =
  info "mounting libp2p ping protocol"

  node.libp2pPing = Ping.new(rng = node.rng)

  node.switch.mount(node.libp2pPing)

proc keepaliveLoop(node: WakuNode, keepalive: chronos.Duration) {.async.} =
  while node.started:
    # Keep all connected peers alive while running
    trace "Running keepalive"

    # First get a list of connected peer infos
    let peers = node.peerManager.peers()
                                .filterIt(node.peerManager.connectedness(it.peerId) == Connected)
                                .mapIt(it.toPeerInfo())

    # Attempt to retrieve and ping the active outgoing connection for each peer
    for peer in peers:
      let connOpt = await node.peerManager.dialPeer(peer, PingCodec)

      if connOpt.isNone:
        # @TODO more sophisticated error handling here
        debug "failed to connect to remote peer", peer=peer
        waku_node_errors.inc(labelValues = ["keep_alive_failure"])
        return

      discard await node.libp2pPing.ping(connOpt.get())  # Ping connection
    
    await sleepAsync(keepalive)

proc startKeepalive*(node: WakuNode) =
  let defaultKeepalive = 5.minutes # 50% of the default chronosstream timeout duration

  info "starting keepalive", keepalive=defaultKeepalive

  asyncSpawn node.keepaliveLoop(defaultKeepalive)

## Helpers
proc dialPeer*(n: WakuNode, address: string) {.async.} =
  info "dialPeer", address = address
  # XXX: This turns ipfs into p2p, not quite sure why
  let remotePeer = parsePeerInfo(address)

  info "Dialing peer", wireAddr = remotePeer.addrs[0], peerId = remotePeer.peerId
  # NOTE This is dialing on WakuRelay protocol specifically
  discard await n.peerManager.dialPeer(remotePeer, WakuRelayCodec)
  info "Post peerManager dial"

proc setStorePeer*(n: WakuNode, address: string) =
  info "Set store peer", address = address

  let remotePeer = parsePeerInfo(address)

  n.wakuStore.setPeer(remotePeer)

proc setFilterPeer*(n: WakuNode, address: string) =
  info "Set filter peer", address = address

  let remotePeer = parsePeerInfo(address)

  n.wakuFilter.setPeer(remotePeer)

proc setLightPushPeer*(n: WakuNode, address: string) =
  info "Set lightpush peer", address = address

  let remotePeer = parsePeerInfo(address)

  n.wakuLightPush.setPeer(remotePeer)

proc connectToNodes*(n: WakuNode, nodes: seq[string]) {.async.} =
  for nodeId in nodes:
    info "connectToNodes", node = nodeId
    # XXX: This seems...brittle
    await dialPeer(n, nodeId)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(5.seconds)

proc connectToNodes*(n: WakuNode, nodes: seq[PeerInfo]) {.async.} =
  for peerInfo in nodes:
    info "connectToNodes", peer = peerInfo
    discard await n.peerManager.dialPeer(peerInfo, WakuRelayCodec)

  # The issue seems to be around peers not being fully connected when
  # trying to subscribe. So what we do is sleep to guarantee nodes are
  # fully connected.
  #
  # This issue was known to Dmitiry on nim-libp2p and may be resolvable
  # later.
  await sleepAsync(5.seconds)

when isMainModule:
  import
    system/ansi_c,
    confutils, json_rpc/rpcserver, metrics,
    ./config, 
    ./jsonrpc/[admin_api,
               debug_api,
               filter_api,
               private_api,
               relay_api,
               store_api],
    ./storage/message/waku_message_store,
    ./storage/peer/waku_peer_storage,
    ../../common/utils/nat

  proc startRpc(node: WakuNode, rpcIp: ValidIpAddress, rpcPort: Port, conf: WakuNodeConf) =
    let
      ta = initTAddress(rpcIp, rpcPort)
      rpcServer = newRpcHttpServer([ta])
    installDebugApiHandlers(node, rpcServer)

    # Install enabled API handlers:
    if conf.relay:
      let topicCache = newTable[string, seq[WakuMessage]]()
      installRelayApiHandlers(node, rpcServer, topicCache)
      if conf.rpcPrivate:
        # Private API access allows WakuRelay functionality that 
        # is backwards compatible with Waku v1.
        installPrivateApiHandlers(node, rpcServer, node.rng, topicCache)
    
    if conf.filter:
      let messageCache = newTable[ContentTopic, seq[WakuMessage]]()
      installFilterApiHandlers(node, rpcServer, messageCache)
    
    if conf.store:
      installStoreApiHandlers(node, rpcServer)
    
    if conf.rpcAdmin:
      installAdminApiHandlers(node, rpcServer)
    
    rpcServer.start()
    info "RPC Server started", ta

  proc startMetricsServer(serverIp: ValidIpAddress, serverPort: Port) =
      info "Starting metrics HTTP server", serverIp, serverPort
      
      startMetricsHttpServer($serverIp, serverPort)

      info "Metrics HTTP server started", serverIp, serverPort

  proc startMetricsLog() =
    # https://github.com/nim-lang/Nim/issues/17369
    var logMetrics: proc(udata: pointer) {.gcsafe, raises: [Defect].}
    logMetrics = proc(udata: pointer) =
      {.gcsafe.}:
        # TODO: libp2p_pubsub_peers is not public, so we need to make this either
        # public in libp2p or do our own peer counting after all.
        var
          totalMessages = 0.float64

        for key in waku_node_messages.metrics.keys():
          try:
            totalMessages = totalMessages + waku_node_messages.value(key)
          except KeyError:
            discard

      info "Node metrics", totalMessages
      discard setTimer(Moment.fromNow(2.seconds), logMetrics)
    discard setTimer(Moment.fromNow(2.seconds), logMetrics)
  
  let
    conf = WakuNodeConf.load()

  # Storage setup
  var sqliteDatabase: SqliteDatabase

  if conf.dbPath != "":
    let dbRes = SqliteDatabase.init(conf.dbPath)
    if dbRes.isErr:
      warn "failed to init database", err = dbRes.error
      waku_node_errors.inc(labelValues = ["init_db_failure"])
    else:
      sqliteDatabase = dbRes.value
      
  var pStorage: WakuPeerStorage

  if conf.persistPeers and not sqliteDatabase.isNil:
    let res = WakuPeerStorage.new(sqliteDatabase)
    if res.isErr:
      warn "failed to init new WakuPeerStorage", err = res.error
      waku_node_errors.inc(labelValues = ["init_store_failure"])
    else:
      pStorage = res.value

  let
    (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat, clientId,
      Port(uint16(conf.tcpPort) + conf.portsShift),
      Port(uint16(conf.udpPort) + conf.portsShift))
    ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
    ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
    ## config, the external port is the same as the bind port.
    extPort = if extIp.isSome() and extTcpPort.isNone(): some(Port(uint16(conf.tcpPort) + conf.portsShift))
              else: extTcpPort
    node = WakuNode.init(conf.nodekey,
                         conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift), 
                         extIp, extPort,
                         pStorage)

  waitFor node.start()

  if conf.swap:
    mountSwap(node)

  # TODO Set swap peer, for now should be same as store peer

  # Store setup
  if (conf.storenode != "") or (conf.store):
    var store: WakuMessageStore
    if (not sqliteDatabase.isNil) and conf.persistMessages:

      # run migration 
      info "running migration ... "
      let migrationResult = sqliteDatabase.migrate(MESSAGE_STORE_MIGRATION_PATH)
      if migrationResult.isErr:
        warn "migration failed"
      else:
        info "migration is done"

      let res = WakuMessageStore.init(sqliteDatabase)
      if res.isErr:
        warn "failed to init WakuMessageStore", err = res.error
        waku_node_errors.inc(labelValues = ["init_store_failure"])
      else:
        store = res.value

    mountStore(node, store, conf.persistMessages)

    if conf.storenode != "":
      setStorePeer(node, conf.storenode)
    

  # Relay setup
  mountRelay(node,
             conf.topics.split(" "),
             rlnRelayEnabled = conf.rlnRelay,
             relayMessages = conf.relay) # Indicates if node is capable to relay messages
  
  # Keepalive mounted on all nodes
  mountLibp2pPing(node)
  
  # Resume historical messages, this has to be called after the relay setup           
  if conf.store and conf.persistMessages:
    waitFor node.resume()

  if conf.staticnodes.len > 0:
    waitFor connectToNodes(node, conf.staticnodes)

  # NOTE Must be mounted after relay
  if (conf.lightpushnode != "") or (conf.lightpush):
    mountLightPush(node)

    if conf.lightpushnode != "":
      setLightPushPeer(node, conf.lightpushnode)
  
  # Filter setup. NOTE Must be mounted after relay
  if (conf.filternode != "") or (conf.filter):
    mountFilter(node)

    if conf.filternode != "":
      setFilterPeer(node, conf.filternode)

  if conf.rpc:
    startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift), conf)

  if conf.metricsLogging:
    startMetricsLog()

  if conf.metricsServer:
    startMetricsServer(conf.metricsServerAddress,
      Port(conf.metricsServerPort + conf.portsShift))
  
  # Setup graceful shutdown
  
  # Handle Ctrl-C SIGINT
  proc handleCtrlC() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    info "Shutting down after receiving SIGINT"
    waitFor node.stop()
    quit(QuitSuccess)
  
  setControlCHook(handleCtrlC)

  # Handle SIGTERM
  when defined(posix):
    proc handleSigterm(signal: cint) {.noconv.} =
      info "Shutting down after receiving SIGTERM"
      waitFor node.stop()
      quit(QuitSuccess)
    
    c_signal(SIGTERM, handleSigterm)
  
  # Start keepalive, if enabled
  if conf.keepAlive:
    node.startKeepalive()

  runForever()
