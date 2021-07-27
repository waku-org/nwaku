{.push raises: [Defect].}

import
  std/[options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/shims/net as stewNet,
  eth/keys,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/builders,
  ../protocol/[waku_relay, waku_message],
  ../protocol/waku_store/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter/waku_filter,
  ../protocol/waku_lightpush/waku_lightpush,
  ../protocol/waku_rln_relay/waku_rln_relay_types,
  ../utils/peers,
  ../utils/requests,
  ./storage/migration/migration_types,
  ./peer_manager/peer_manager

export
  builders,
  waku_relay, waku_message,
  waku_store,
  waku_swap,
  waku_filter,
  waku_lightpush,
  waku_rln_relay_types

when defined(rln):
  import
    libp2p/protocols/pubsub/rpc/messages,
    web3,
    ../protocol/waku_rln_relay/[rln, waku_rln_relay_utils]

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
    filters*: Filters
    rng*: ref BrHmacDrbgContext
    started*: bool # Indicates that node has started listening

proc protocolMatcher(codec: string): Matcher =
  ## Returns a protocol matcher function for the provided codec
  proc match(proto: string): bool {.gcsafe.} =
    ## Matches a proto with any postfix to the provided codec.
    ## E.g. if the codec is `/vac/waku/filter/2.0.0` it matches the protos:
    ## `/vac/waku/filter/2.0.0`, `/vac/waku/filter/2.0.0-beta3`, `/vac/waku/filter/2.0.0-actualnonsense`
    return proto.startsWith(codec)

  return match

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

proc new*(T: type WakuNode, nodeKey: crypto.PrivateKey,
    bindIp: ValidIpAddress, bindPort: Port,
    extIp = none[ValidIpAddress](), extPort = none[Port](),
    peerStorage: PeerStorage = nil): T 
    {.raises: [Defect, LPError].} =
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
  let wakuNode = WakuNode(
    peerManager: PeerManager.new(switch, peerStorage),
    switch: switch,
    rng: rng,
    peerInfo: peerInfo,
    filters: initTable[string, Filter]()
  )

  return wakuNode

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
      # Notify mounted protocols of new message
      if (not node.wakuFilter.isNil):
        await node.wakuFilter.handleMessage(topic, msg.value())
      
      if (not node.wakuStore.isNil):
        await node.wakuStore.handleMessage(topic, msg.value())

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

proc mountFilter*(node: WakuNode) {.raises: [Defect, KeyError, LPError]} =
  info "mounting filter"
  proc filterHandler(requestId: string, msg: MessagePush)
    {.gcsafe, raises: [Defect, KeyError].} =
    
    info "push received"
    for message in msg.messages:
      node.filters.notify(message, requestId) # Trigger filter handlers on a light node
      waku_node_messages.inc(labelValues = ["filter"])

  node.wakuFilter = WakuFilter.init(node.peerManager, node.rng, filterHandler)
  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterCodec))

# NOTE: If using the swap protocol, it must be mounted before store. This is
# because store is using a reference to the swap protocol.
proc mountSwap*(node: WakuNode, swapConfig: SwapConfig = SwapConfig.init()) {.raises: [Defect, LPError].} =
  info "mounting swap", mode = $swapConfig.mode
  node.wakuSwap = WakuSwap.init(node.peerManager, node.rng, swapConfig)
  node.switch.mount(node.wakuSwap, protocolMatcher(WakuSwapCodec))
  # NYI - Do we need this?
  #node.subscriptions.subscribe(WakuSwapCodec, node.wakuSwap.subscription())

proc mountStore*(node: WakuNode, store: MessageStore = nil, persistMessages: bool = false) {.raises: [Defect, LPError].} =
  info "mounting store"

  if node.wakuSwap.isNil:
    debug "mounting store without swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store, persistMessages=persistMessages)
  else:
    debug "mounting store with swap"
    node.wakuStore = WakuStore.init(node.peerManager, node.rng, store, node.wakuSwap, persistMessages=persistMessages)

  node.switch.mount(node.wakuStore, protocolMatcher(WakuStoreCodec))

when defined(rln):
  proc mountRlnRelay*(node: WakuNode,
                      ethClientAddress: Option[string] = none(string),
                      ethAccountAddress: Option[Address] = none(Address),
                      membershipContractAddress:  Option[Address] = none(Address)) {.async.} =
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


  proc addRLNRelayValidator*(node: WakuNode, pubsubTopic: string) =
    ## this procedure is a thin wrapper for the pubsub addValidator method
    ## it sets message validator on the given pubsubTopic, the validator will check that
    ## all the messages published in the pubsubTopic have a valid zero-knowledge proof 
    proc validator(topic: string, message: messages.Message): Future[ValidationResult] {.async.} =
      let msg = WakuMessage.init(message.data) 
      if msg.isOk():
        #  check the proof
        if proofVrfy(msg.value().payload, msg.value().proof):
          return ValidationResult.Accept
    # set a validator for the pubsubTopic 
    let pb  = PubSub(node.wakuRelay)
    pb.addValidator(pubsubTopic, validator)

proc startRelay*(node: WakuNode) {.async.} =
  if node.wakuRelay.isNil:
    trace "Failed to start relay. Not mounted."
    return

  ## Setup and start relay protocol
  info "starting relay"
  
  # Topic subscriptions
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

  when defined(rln):
    if node.wakuRelay.rlnRelayEnabled:
      # TODO currently the message validator is set for the defaultTopic, this can be configurable to accept other pubsub topics as well 
      addRLNRelayValidator(node, defaultTopic)
      info "WakuRLNRelay is mounted successfully"
  
  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc mountRelay*(node: WakuNode,
                 topics: seq[string] = newSeq[string](),
                 rlnRelayEnabled = false,
                 relayMessages = true,
                 triggerSelf = true)
  # @TODO: Better error handling: CatchableError is raised by `waitFor`
  {.gcsafe, raises: [Defect, InitializationError, LPError, CatchableError].} = 

  let wakuRelay = WakuRelay.init(
    switch = node.switch,
    # Use default
    #msgIdProvider = msgIdProvider,
    triggerSelf = triggerSelf,
    sign = false,
    verifySignature = false
  )
  
  info "mounting relay", rlnRelayEnabled=rlnRelayEnabled, relayMessages=relayMessages

  ## The default relay topics is the union of
  ## all configured topics plus the hard-coded defaultTopic(s)
  wakuRelay.defaultTopics = concat(@[defaultTopic], topics)
  wakuRelay.rlnRelayEnabled = rlnRelayEnabled

  node.switch.mount(wakuRelay, protocolMatcher(WakuRelayCodec))

  if relayMessages:
    ## Some nodes may choose not to have the capability to relay messages (e.g. "light" nodes).
    ## All nodes, however, currently require WakuRelay, regardless of desired capabilities.
    ## This is to allow protocol stream negotation with relay-capable nodes to succeed.
    ## Here we mount relay on the switch only, but do not proceed to subscribe to any pubsub
    ## topics. We also never start the relay protocol. node.wakuRelay remains nil.
    ## @TODO: in future, this WakuRelay dependency will be removed completely  
    node.wakuRelay = wakuRelay

  when defined(rln):
    if rlnRelayEnabled:
      # TODO pass rln relay inputs to this proc, right now it uses default values that are set in the mountRlnRelay proc
      info "WakuRLNRelay is enabled"
      waitFor mountRlnRelay(node)
      info "WakuRLNRelay is mounted successfully"

  info "relay mounted successfully"

  if node.started:
    # Node has started already. Let's start relay too.
    waitFor node.startRelay()

proc mountLightPush*(node: WakuNode) {.raises: [Defect, LPError].} =
  info "mounting light push"

  if node.wakuRelay.isNil:
    debug "mounting lightpush without relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil)
  else:
    debug "mounting lightpush with relay"
    node.wakuLightPush = WakuLightPush.init(node.peerManager, node.rng, nil, node.wakuRelay)
  
  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))

proc mountLibp2pPing*(node: WakuNode) {.raises: [Defect, LPError].} =
  info "mounting libp2p ping protocol"

  try:
    node.libp2pPing = Ping.new(rng = node.rng)
  except Exception as e:
    # This is necessary as `Ping.new*` does not have explicit `raises` requirement
    # @TODO: remove exception handling once explicit `raises` in ping module
    raise newException(LPError, "Failed to initialize ping protocol")

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

proc setStorePeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
  info "Set store peer", address = address

  let remotePeer = parsePeerInfo(address)

  n.wakuStore.setPeer(remotePeer)

proc setFilterPeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
  info "Set filter peer", address = address

  let remotePeer = parsePeerInfo(address)

  n.wakuFilter.setPeer(remotePeer)

proc setLightPushPeer*(n: WakuNode, address: string) {.raises: [Defect, ValueError, LPError].} =
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

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.
  ##
  ## Status: Implemented.
  
  node.libp2pTransportLoops = await node.switch.start()
  
  # TODO Get this from WakuNode obj
  let peerInfo = node.peerInfo
  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs
  let listenStr = $peerInfo.addrs[^1] & "/p2p/" & $peerInfo.peerId
  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr

  if not node.wakuRelay.isNil:
    await node.startRelay()
  
  info "Node started successfully"
  node.started = true

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil:
    await node.wakuRelay.stop()

  await node.switch.stop()

  node.started = false

{.pop.} # @TODO confutils.nim(775, 17) Error: can raise an unlisted exception: ref IOError
when isMainModule:
  ## Node setup happens in 6 phases:
  ## 1. Set up storage
  ## 2. Initialize node
  ## 3. Mount and initialize configured protocols
  ## 4. Start node and mounted protocols
  ## 5. Start monitoring tools and external interfaces
  ## 6. Setup graceful shutdown hooks

  import
    confutils,
    system/ansi_c,
    ../../common/utils/nat,
    ./config,
    ./waku_setup,
    ./storage/message/waku_message_store,
    ./storage/peer/waku_peer_storage
  
  logScope:
    topics = "wakunode.setup"
  
  ###################
  # Setup functions #
  ###################

  # 1/6 Setup storage
  proc setupStorage(conf: WakuNodeConf):
    SetupResult[tuple[pStorage: WakuPeerStorage, mStorage: WakuMessageStore]] =

    ## Setup a SQLite Database for a wakunode based on a supplied
    ## configuration file and perform all necessary migration.
    ## 
    ## If config allows, return peer storage and message store
    ## for use elsewhere.
    
    var
      sqliteDatabase: SqliteDatabase
      storeTuple: tuple[pStorage: WakuPeerStorage, mStorage: WakuMessageStore]

    # Setup DB
    if conf.dbPath != "":
      let dbRes = SqliteDatabase.init(conf.dbPath)
      if dbRes.isErr:
        warn "failed to init database", err = dbRes.error
        waku_node_errors.inc(labelValues = ["init_db_failure"])
        return err("failed to init database")
      else:
        sqliteDatabase = dbRes.value

    if not sqliteDatabase.isNil:
      # Database initialized. Let's set it up
      sqliteDatabase.runMigrations(conf) # First migrate what we have

      if conf.persistPeers:
        # Peer persistence enable. Set up Peer table in storage
        let res = WakuPeerStorage.new(sqliteDatabase)

        if res.isErr:
          warn "failed to init new WakuPeerStorage", err = res.error
          waku_node_errors.inc(labelValues = ["init_store_failure"])
        else:
          storeTuple.pStorage = res.value
      
      if conf.persistMessages:
        # Historical message persistence enable. Set up Message table in storage
        let res = WakuMessageStore.init(sqliteDatabase)

        if res.isErr:
          warn "failed to init WakuMessageStore", err = res.error
          waku_node_errors.inc(labelValues = ["init_store_failure"])
        else:
          storeTuple.mStorage = res.value
    
    ok(storeTuple)

  # 2/6 Initialize node
  proc initNode(conf: WakuNodeConf,
                pStorage: WakuPeerStorage = nil): SetupResult[WakuNode] =
    
    ## Setup a basic Waku v2 node based on a supplied configuration
    ## file. Optionally include persistent peer storage.
    ## No protocols are mounted yet.

    let
      (extIp, extTcpPort, extUdpPort) = setupNat(conf.nat,
                                                clientId,
                                                Port(uint16(conf.tcpPort) + conf.portsShift),
                                                Port(uint16(conf.udpPort) + conf.portsShift))
      ## @TODO: the NAT setup assumes a manual port mapping configuration if extIp config is set. This probably
      ## implies adding manual config item for extPort as well. The following heuristic assumes that, in absence of manual
      ## config, the external port is the same as the bind port.
      extPort = if extIp.isSome() and extTcpPort.isNone():
                  some(Port(uint16(conf.tcpPort) + conf.portsShift))
                else:
                  extTcpPort
      node = WakuNode.new(conf.nodekey,
                          conf.listenAddress, Port(uint16(conf.tcpPort) + conf.portsShift), 
                          extIp, extPort,
                          pStorage)
    
    ok(node)

  # 3/6 Mount and initialize configured protocols
  proc setupProtocols(node: var WakuNode,
                       conf: WakuNodeConf,
                       mStorage: WakuMessageStore = nil): SetupResult[bool] =
    
    ## Setup configured protocols on an existing Waku v2 node.
    ## Optionally include persistent message storage.
    ## No protocols are started yet.
    
    # Mount relay on all nodes
    mountRelay(node,
              conf.topics.split(" "),
              rlnRelayEnabled = conf.rlnRelay,
              relayMessages = conf.relay) # Indicates if node is capable to relay messages
    
    # Keepalive mounted on all nodes
    mountLibp2pPing(node)
    
    if conf.swap:
      mountSwap(node)
      # TODO Set swap peer, for now should be same as store peer

    # Store setup
    if (conf.storenode != "") or (conf.store):
      mountStore(node, mStorage, conf.persistMessages)

      if conf.storenode != "":
        setStorePeer(node, conf.storenode)

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
    
    ok(true) # Success

  # 4/6 Start node and mounted protocols
  proc startNode(node: WakuNode, conf: WakuNodeConf): SetupResult[bool] =
    ## Start a configured node and all mounted protocols.
    ## Resume history, connect to static nodes and start
    ## keep-alive, if configured.

    # Start Waku v2 node
    waitFor node.start()
    
    # Resume historical messages, this has to be called after the node has been started
    if conf.store and conf.persistMessages:
      waitFor node.resume()
    
    # Connect to configured static nodes
    if conf.staticnodes.len > 0:
      waitFor connectToNodes(node, conf.staticnodes)

    # Start keepalive, if enabled
    if conf.keepAlive:
      node.startKeepalive()
    
    ok(true) # Success

  # 5/6 Start monitoring tools and external interfaces
  proc startExternal(node: WakuNode, conf: WakuNodeConf): SetupResult[bool] =
    ## Start configured external interfaces and monitoring tools
    ## on a Waku v2 node, including the RPC API and metrics
    ## monitoring ports.
    
    if conf.rpc:
      startRpc(node, conf.rpcAddress, Port(conf.rpcPort + conf.portsShift), conf)

    if conf.metricsLogging:
      startMetricsLog()

    if conf.metricsServer:
      startMetricsServer(conf.metricsServerAddress,
        Port(conf.metricsServerPort + conf.portsShift))
    
    ok(true) # Success
  
  let
    conf = WakuNodeConf.load()
  
  var
    node: WakuNode  # This is the node we're going to setup using the conf

  ##############
  # Node setup #
  ##############

  debug "1/6 Setting up storage"

  var
    pStorage: WakuPeerStorage
    mStorage: WakuMessageStore
  
  let setupStorageRes = setupStorage(conf)

  if setupStorageRes.isErr:
    error "1/6 Setting up storage failed. Continuing without storage."
  else:
    (pStorage, mStorage) = setupStorageRes.get()

  debug "2/6 Initializing node"

  let initNodeRes = initNode(conf, pStorage)

  if initNodeRes.isErr:
    error "2/6 Initializing node failed. Quitting."
    quit(QuitFailure)
  else:
    node = initNodeRes.get()

  debug "3/6 Mounting protocols"

  let setupProtocolsRes = setupProtocols(node, conf, mStorage)

  if setupProtocolsRes.isErr:
    error "3/6 Mounting protocols failed. Continuing in current state."

  debug "4/6 Starting node and mounted protocols"
  
  let startNodeRes = startNode(node, conf)

  if startNodeRes.isErr:
    error "4/6 Starting node and mounted protocols failed. Continuing in current state."

  debug "5/6 Starting monitoring and external interfaces"

  let startExternalRes = startExternal(node, conf)

  if startExternalRes.isErr:
    error "5/6 Starting monitoring and external interfaces failed. Continuing in current state."

  debug "6/6 Setting up shutdown hooks"

  # 6/6 Setup graceful shutdown hooks
  ## Setup shutdown hooks for this process.
  ## Stop node gracefully on shutdown.
  
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
  
  debug "Node setup complete"

  runForever()
