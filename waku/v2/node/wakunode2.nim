{.push raises: [Defect].}

import
  std/[options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/shims/net as stewNet,
  stew/byteutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/nameresolving/dnsresolver,
  libp2p/builders,
  ../protocol/[waku_relay, waku_message],
  ../protocol/waku_store/waku_store,
  ../protocol/waku_swap/waku_swap,
  ../protocol/waku_filter/waku_filter,
  ../protocol/waku_lightpush/waku_lightpush,
  ../protocol/waku_rln_relay/[waku_rln_relay_types], 
  ../utils/peers,
  ../utils/requests,
  ./storage/migration/migration_types,
  ./peer_manager/peer_manager,
  ./dnsdisc/waku_dnsdisc

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
    ../protocol/waku_rln_relay/[rln, waku_rln_relay_utils, waku_rln_relay_utils]

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
    enr*: enr.Record
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
    enrIp = if extIp.isSome(): extIp
            else: some(bindIp)
    enrTcpPort = if extPort.isSome(): extPort
                 else: some(bindPort)
    enr = createEnr(nodeKey, enrIp, enrTcpPort, none(Port))
  
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
    enr: enr,
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
                      ethClientAddrOpt: Option[string] = none(string),
                      ethAccAddrOpt: Option[Address] = none(Address),
                      memContractAddOpt:  Option[Address] = none(Address),
                      groupOpt: Option[seq[IDCommitment]] = none(seq[IDCommitment]),
                      memKeyPairOpt: Option[MembershipKeyPair] = none(MembershipKeyPair),
                      memIndexOpt: Option[uint] = none(uint)) {.async.} =
    # TODO return a bool value to indicate the success of the call
    # check whether inputs are provided
    if ethClientAddrOpt.isNone():
      info "failed to mount rln relay: Ethereum client address is not provided"
      return
    if ethAccAddrOpt.isNone():
      info "failed to mount rln relay: Ethereum account address is not provided"
      return
    if memContractAddOpt.isNone():
      info "failed to mount rln relay: membership contract address is not provided"
      return
    if groupOpt.isNone():
      # TODO this check is not necessary for a dynamic group
      info "failed to mount rln relay:  group information is not provided"
      return
    if memKeyPairOpt.isNone():
      info "failed to mount rln relay: membership key of the node is not provided"
      return
    if memIndexOpt.isNone():
      info "failed to mount rln relay:  membership index is not provided"
      return

    let 
      ethClientAddr = ethClientAddrOpt.get()
      ethAccAddr = ethAccAddrOpt.get()
      memContractAdd = memContractAddOpt.get()
      group = groupOpt.get()
      memKeyPair = memKeyPairOpt.get()
      memIndex = memIndexOpt.get()


    # check the peer's index and the inclusion of user's identity commitment in the group
    doAssert((memKeyPair.idCommitment)  == group[int(memIndex)])

    # create an RLN instance
    var rlnInstance = createRLNInstance(32)
    doAssert(rlnInstance.isOk)
    var rln = rlnInstance.value

    # generate the membership keys if none is provided
    # this if condition never gets through for a static group of users
    # the node should pass its keys i.e., memKeyPairOpt to the function
    if not memKeyPairOpt.isSome:
      let membershipKeyPair = rln.membershipKeyGen()
      # check whether keys are generated
      doAssert(membershipKeyPair.isSome())
      debug "the membership key for the rln relay is generated", idKey=membershipKeyPair.get().idKey.toHex, idCommitment=membershipKeyPair.get().idCommitment.toHex


    # add members to the Merkle tree
    for index in 0..group.len-1:
      let member = group[index]
      let member_is_added = rln.insertMember(member)
      doAssert(member_is_added)
    
    # create the WakuRLNRelay
    var rlnPeer = WakuRLNRelay(membershipKeyPair: memKeyPair,
      membershipIndex: memIndex,
      membershipContractAddress: memContractAdd,
      ethClientAddress: ethClientAddr,
      ethAccountAddress: ethAccAddr,
      rlnInstance: rln)
    
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
                 rlnRelayMemIndex = uint(0),
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
      # TODO get user inputs via cli options
      info "WakuRLNRelay is enabled"

      # a static list of membership keys in hex
      var groupKeys: seq[string] = @["045a90832558f7b56f3f38f56f70bccba392d84f3f1b64ccba6ba21daaf57a1f", "200be495af932e6f83e384393854fb60ec02245f2d630cbb9c701fc9d25f112e", "2e8718c8db83471a19ade90fa1782a593e89f0e6e1555dfcae02d768c155910d", "54e7f26866aae4af2bf3ba81c9d76516c7c2e26a3aa130ae660f05ea3528691c", "545e00fa9a083c962875831b956c9d0d25d27b10b0b02da7feb7f6f3ad474205", "2c57d1be4785d7bb8341635784e48e6f656ee9574f593298302bb15c5583d22a", "d24e4ff2c21ec63c9148887b2a6bd0c2c5daae4bbe889480778f870afea7a02a", "4c338455697992fa98f45cfeda63d6fc7c384e0aebc6603f646f2ed9ec0df204", "9c2d78394523e90ebdfd407a3fe5c31b3bb30d3061358c9fcda6480e1633cd1c", "bee9f122f9fc1887e134f9fe3a55e60cda416263ce1cdd7802fa96b7b0f52619", "0298173e7f2996bd69b4992ac58927fba845b32a919065230bb4c6b377245c05", "7418e583da831e51fa78a90e033f0fcb676adf82af5d03669a002f61cf3ef22e", "1db9bf1a1fdf04d9c8452d5f6c86214f2dc1cdcc56bb3b5f62bcb50282651c21", "27e0c4c13f6e1deea4f7a574269b5f9567645985a21f15b266bc052a856b581f", "714c1f0f5fc782881d26451b2045d68236addc4a782af90b33d8130d1dc2d310", "c3796a90f73a8fd6e9a2e6702075b5b61bd36377cd3f1fba2e55cca60ddcb103", "3721ee9c258a12a96c6db2bd6b85407c20690616c7868cc40cfb78e9f81bba16", "1f569e32ce5f6b31a186bccdeae0dcf0d870462b1ce65ae83972e6f785fbae1d", "ba0746316fdb3e14ed192f62a23f98debfcd3eabe4ae23251e9ecf15032b8312", "2926e40f2f62941e99dda1b647b688f604f224aee3dccb4976cdfccba24aee0b", "c313bc470095373af1efb21f48f7e85935090c02ca016c04adf5650adb28f90a", "eaa5e761efc64949b88ab7eac0fc5331fa4c0c0e755c396983b7873801b5fd0b", "bc69b2eeddeec3a38571de8ebd5782d2230a67eb537aae250bee648eefe89c04", "2f5d17486c310970ace7805773d7654dd9fbc4c254b61fa4612af9b96ba06b17", "00e8fe8d60db239059667286e00804d60b7a93209fbae65f30965a1df26e9717", "599fdd0300101fe0549303e22bb241c2178275448154e09ea0a2ab85ffd26127", "bafb62cf0f58dd3ca10648d64a81318f73dd5d118e9b11e1c5a46a3f7dacb40d", "121c481780bf68cc3bcb1161f30708baf58ee1f06ae57825804cf3ce95869a2a", "6b120e48b20e704efa239b87f0e457ab260bdea86a2f19fac435874685df2d24", "ac00443f4255d5ebcd778b12bd9f0fd957346013a543145549af1cd8f0e8ef0d", "0f444131b66f1728a3eac51eb71b56ffdeef212e5d61a07f3e18b83672677c2d", "66a1fcb111aaa3263f3ce6a44fd0f2722feae4d1d0c6595a69b4d75d595a6b0a", "e0356a4540c0a63f3db9806cf1872fe3d8739276f83f02de0e2165042b841d01", "8e6ce8380c1505b1f9574817d12b5260bb78e9fff4ef56847346caed04401621", "c276a0e8d1e07b033d8df997d7d3f2fdb23054bc63ccaa50aa96580d3f29361b", "a2af0da6570d64e85bbf6facf95a7cf31f956a2c67b5d504faa4c134fea87217", "e827cffe6c4fb0344da12553d3faa9941d4853347ae36f3ed52804008d0f7d12", "6a17410be22fb451aef5735c60ccde0d1eb7be8d73ca11de5b8b96e7b6be562d", "ad69abf808d588f0537711ee4ab5dd1e011df1813ef24c31f7983210549a030b", "ffcbf2541c6e3acfb37a54f527640ac1b1367e5cc21da8f1b5dfc47214d4e522", "11a90106826a400bb6628cf3dd7b6674dde748910fef9418c61989e909c9b40d", "cb8956af468762bef2862e6626191b06ce3cf48473183b85dac23fb95bab4f2e", "f17f5d129443c8edf7a23355243e71798b3cdcc0bee6959935a03900d1064e25", "b624bfb786355e3d43d8e2ca98fb714d294cfcce03d42930ccccdfda8ad0e700", "d99fa2e837cf8c2028f57bbb1ea7c57b275cd60b0b9fc902916d240bb6a7ef13", "38a6b9f4866f01386e4a5cdd356bea57a1ce2699776bb48bf627a0b2ae061a09", "5280ff755b61db6ba308ab3291ed9e8f0d65f085443353352a1fbe550aa00f30", "7c78c04922860a2312d828a8909f1a92ec7b1cda2486d0a89e1e3d9f11b4ea07", "cba1a3d0dbfd52a3e3e5e06bd59598a292fd055f6440220c47a013a1c0136f01", "971f4f3129beb2583e55c144a503cd36bed3e6683039c22312e286c70b892110", "46c3287345015ce73bcfeeea2c1c6ad148a6f2b8148d1cf12242cc9d950df705", "e227514a7ba26f052b74be7cf889c7585c96b61c4c8a08171e6c01d0a0890329", "f294a8878eff1404798554aeb5741a480f87266434a891c5f2d031dcaf779d0b", "a02b7bfcb8d104cc337181f81981dbdaa764061711da912ad245dc601062c207", "f948319d9bdce7189e7a2d0fad54662fc31d4db65ec17fc7d5f872aff58a3229", "db5f68865a979038cfb6a4c6864417dce91ff1943dae7a20999098f078fc2017", "c0dc0104a386e78f5cd965ccdf1dcb4d85605a652dae4f7202fdfd462e5afa05", "c5ea411c51d5f8fe883169bd0f19fc9a0f679e9ab5db2af8843b6b2d4017d416", "72d02a4694425ef40a39dc2cd9098df56db3f74a23b2a52d433d84023f31ca05", "e208e6e9a5c813524fc8a5e276fed246a59296c99c205e44f5a33290ede46307", "5ecf39f0ae62643215e4df6a201dde895d03ae81c09ab4fd7b72b7398a450f12", "fbf03f846147b4bd911f081032f0e83a9ec3d5a1684b73455b66ecae576e3a1b", "d524bbb6bc1e0354ad38f1a31b0c51e0f437eca2b7aa22f1f2d0d33999c75f22", "8e2f969f2a008bca4d18144cd64ace3c247acef052197dc8c726c3ef82fc9216", "bc0aed2bd28be572d9acbbbd853b1b388b07e952ecde823e66b088e568380318", "205f2a6a4df0f97c7316a33f3d3a1f90e8c90612beb6c57d805889f666d48308", "2b2e0c6dffd6ee44dfd5abbb00b56149139dc0a36f7a364789c72673ebdab121", "1762c0393f65e2e4501de1a79f80f6a8901ece343ef4c35fbfd3548061750c1b", "a4f6818b7bb3d6726844ff7490796b6bda6dd6261c9729ef7b5fbe920fda5918", "2a0adde44ed2522a1ec844e0782130f9f6eb7244151225ed83e1bb46e03e4625", "eb62864d8fc13e42ade611b98c3a4b9bbce97c10ba197ae03583276a7d437218", "5ecee72035d75c94af1b005f98d2cba566502c23a5b72158352aa1b3ae4da90b", "e6d7896131f50c43a44b2eb896bfa8b35b210f7b01300cc40f7276625e993e26", "9cf88658f964ec11a896656e9499b3fd795fe56929c331a43d24acf86ff91829", "259ea41c655dd792759ce7c83244cb28248fccc4bb60d9ea04159cd0dd740018", "6e1dadd3701c4fcb0287f0da2356577e9b6183c468445158e2e6a7ef77e05828", "0433c68f11b980f1e23f1ea0658bf5b704a645200e57ce79b3206d3442118304", "7819c20589291b768ae047231c258f525f601db3a776d165d8504eccb457bf26", "eef7ce831c16d9e4f85e2b6bcdc929669e5d3baf4bd6f3d36658d6aaa025f016", "252c7a218bfd24d1f0b158933abe35fe61da1643f92b0e43270f99e2e5b5ec0f", "16046fe7a01750074f25e90e5ea013c3e7515b198fbaa4ee978a81ef2f6ee11e", "dff60190bf42981b4bd87767215b142599d3c20e6f70c96fc9d2ba0ac874431f", "237e75818240db0dde0dce1ab8eec45fa72462d61c7c94b3603179368e778211", "9a1563a982b1506abf3762ebba2dfeeb2d789f2da81eaaaab78ce0551aeb1124", "ffa838964b4665297ec49a65cfb8705523644d2533fefca2921cad12027ce914", "141e16f5c733b3020666b6dc2406bc6e024e181892f31bd2c5eb8b7f0a1cb304", "6a14878bad098c8c2c524f44f6c319c3ca32d2515b9e3adcca624c8c1c306b2c", "a366fd1004faaaeccbabcdd3e8a353445998cf65cb97dd0dc7feff225f18c70a", "f64fa95f8ea22cc37cb5bf55b9b14202a4362ffaf971dec187eb5a7de26f8918", "871117bca2a71252b4573ea2224d894468e94cf54d08078a985f71f792bf2415", "f6103ad87ed5d36f384aef6fc0c01b718c93c653554f5295011a561398a04f0c", "4219b16d0d6721c6d01b0becb82731bdde63210c6b9422052cb9f01332e6c00a", "26f0f50fae359f4a7c6efb99f9eb1c750ef1ac6884046d5f10dce650eb43262a", "68b3ba9aad1b8c9657efdafd4963941e9463476602ac8c5c522ff2565e9a5b25", "148fee6e326c2b2a21fb5fe7c54f7434e2eed88a8df5f38cb51edcdfb322be14", "e0ab1a832000a19ae1252dbb7aacf7e10ba07521b00f10858a2a8971e8caf72f", "c807b983ec17ed75e6cfbe68c8d0f3a054595998f2015a7b01f99c4c22b5d60f", "576d673f215e47ac00d08ead512c6df90703f222238ba9f4b717d8d113db2815", "2453a4069e246bd117cf44f37bee26b69742c7ed4e017ffbae1b2cee61e7552a", "19cd32a922eb1c05ec539c474d967033fd6dc4b559a3a3bd45b0a7214714f428", "a75d0481c2a99bf39a97c5b42d00330364f0c7f647eff37016963c924746d42a", "4adfce8ebe8f9c261ff386b9e9868fc370eb76e2bc8437a58aca08eabc36452c", "69aea7baf9d7de5023bcc3d72d39e571ab7128860c0f9b20dd0f42be2d67bc2a", "7abb2491782aa116849f6d7ecb04c7176793781b8281c1234fedaa0aec125614", "524ec06001368e1b82df7f95b11c84f3755d5f8347db9b36f9a2e460543f9407", "34db155d11ac9195498fe3085f2d27c867826a2f6c8f85fe3ea0027efd3e4b28", "47ac216c160efe503bbdf729c7db748e751092915c347fc14f9a42e38c71e80f", "872fc7ff0c4f7e3a56859859028757b043a0956980be1ac2eda8fa604622f91d", "d865a5a53d77f42a6efd6a0d54893565b4a917b4524878b494c9b948a7c2a50b", "f162b6d866262070f02d979e44c14894f217fc7c1784c5b22ea62175effabf2a", "22f855fc357bc41f0c9adc57442c0d683f0da51de01f2c8f3953ce065c4b4d10", "794fc6731c72e22d1e9e616500a73ae66565226629fe521bba22a5246f78360f", "1e67f431e204fead6870b8b58aac75c764efb91ad99eaaf916dd45b144e9f622", "a8acd853fcaf910018512945baf9f37d35af168ba66e208b5f590493c97a722f", "2c010b3a1ba788034faee5d4d612b5f2866e279991d52c6c6f28d28a19ad7e1f", "d0454fd9493356dfadf3d44978dd13dba1584dda6981abaeaf31239b24765405", "47313281aa6a4b8f69a224be2a24efc8ba50ae56b2537ddeea72f52e067e2129", "59105b14c0f1c34b8983ecc182152961378673cea3c19329e93b522a6e939b26", "57376021adf6bab8a6c1a28e81adb94ed0cc44a457a89590e516075985c19f13", "4ce2ccb2f94d569def9ac0027b72ce4a060c854ecd308ecd53c5b10403f72003", "9d69c305ad7f7cc207195f63cbb08051feb2b8f279349563241099cde6dfc118", "22cbfa7f81c0a80abd0ec6fc6c498e74ec21d33ed07a59bca8ef6686f2c2a41d", "b656b9290014ee634353f8c5513366cc5d588d2cb5ffb79b453d1cd0466ec717", "84e3b54e4f8215616a31b987ccd450b41469f142db3ccee212e309304cbb342b", "b0eec49f30df542c1acc000b29b3545a0560e98a04448faca1719cd2ee7c7b26", "46821baea0f012a5ec21b05b13d96209fb5846cd27a3607d5fe64cf9442ef318", "2f294cab76254490f3c966d62f132abb21ca01eecb2bf74bf673a3b582c97509", "dfc7b5ece05d38b8e5fcab048ef691e10680956e556dd0f3fd7a11f9d84fdb04", "c7ee2d7534af7ba2a9b0e43e977a245f90e820edfc4429449198c95b405fd62e", "a8861eccfb95827b9d9611819ec8b0b6dc65d0db88311cff8963977e77ffa818", "8e1d34bdad6985cae0abc9ff4bb714b0855a3ecae5f81f637a6ad0216e660107", "de5c35cad3de35657d4d609d24f4166285f032d170370603c27e4eac572ca41b", "7e270d1b92585e3eaa030ab9fe10619a0e35c2d3b8c62c69ca9c3b94d2691d0a", "af17ff3eaaedfcf5499cb720746bd953dd2feb6da8d98c94367369ed0091a826", "d12c44e67ad37e6a20bab1a6dbf21b548e95a7b4c210d94e89c8d22928f6850a", "f4833abce586025007d389c5a6ad24ccd42b0b3d6b22ec6f62c43c5804ead82b", "7b38373e78ae544e84a9d4ed0a4acb05e94f72d1a17f864c37fef3a11f277b07", "d850cfa959ada79b005ded9e6a79983b392c49469c752f150fdd0c4fd22f6729", "ceb220f425d8e5afc5e836101d8094fac6c8f46f79b64f985c8b0b5b90a21e26", "4c5c470fa44a02e7a8f1f675dac853192bad7a24e5f84e0c5054657972a42920", "c19b2efc96bac9acf5ac2ee4b15d312a2c22d3ef50cc058050f02ac2b4b15301", "8dab4c0b08bda620bb63e412a1e8c885192334f18ef106647a4e1151ffca1915", "fdf9f9c8de6326ccc2e711e2729e576c3c76abe2f34fa8fe54b07264ca818505", "44cbe719767d5177e1f4e4d53322b2c66b21a513328c5697afc0b109078b440e", "c822fad5b98c4d3cd4512c046d79fec31627c298b65d545079a77416e353a601", "9cefed3a32434bdef4c72e22ba98289bc4831934f91cd089d8fc1c1c0ab9fa0a", "c95e5f962f083e3c76843818ea096458ae867bf3f696ec4eb9319e2ee267f013", "9afc1cf3fbedaeb81eef6d4298ad7c3f25883afd9331b115ac89d26e01e74719", "f91275b89dc2d2f55a2bb19f54c29a639b6895b3f19fa4d455371c459e268e1d", "f4478da6a4b738dc92fe5c5794a596dd42659d92485b8511e8b6ec1441ce3b23", "d4578946c19ca9ed67186b9ede9ae3334ab166383c584755c7a49bf6387a3015", "cd4b3f127f17b6d3c4253239330fe9b683a529613fe27c2f53698701b6b71b24", "c70351fab047486a8868b940492e9b66730ce659384eecfa2211feae5b626a15", "239c6738175956aed095a33edc83cf08038aa830a69da53fda1a092e0997c60b", "06f4ffe55ff71b78cf5e78497d2ea525973ef2231fcc0552ec788d1362b50325", "f93adfc53d73675148b79ee2d3c51774412f2af4ccf5814ef276ac2024671e26", "5c9af59018e86e3b717a88b2c08e1b6e9a44b5fe64adc25ac1751c8182eeb312", "4196b9532b071f04bdf27837026beb8b062a7c7de33f9e7bcb5b05d8651bdf07", "2700d1680cdfd84a4941610608bff1bdc330ae8a94be24567c189864b266c616", "3f90fa45595427e189067fc5d1b8bb21cbfc4d54530aa3b78266587d2239f41c", "8c80075af391945307627bbc4a4ea6406bd57608445748ece82ef0bae037f60e", "b0c798a4bd153e9420be8211f4360d79d7c3479316b98b548c416c491e80dc1a", "cf2a0dadea865534d471efb19d4001801e5e5695342c7e198a46abfd51bc2b25", "edc85e19f95f66e8d7f2b49e6d00d0473dac9efedee53cbbee578391ce7b9f05", "cebad61c29ce8a4482287b737a7688325571d045b814a966a7ba5a307503dc0f", "214dda0412bef8e0b1d53b2b056091a9c7355c8dbf2f11048a2f3737fb005828", "219961a17263ae29db21cc32589271ccf6dc3416740daafde9a4d93f0416e817", "d6d68ec08be07fa3f5e85497ba6f5a042a18c5ea543da8f9f6615839d0748f05", "ceef793da479045c207be9f827d10dbba1d1637cf0a2d4100d34bad53d82d32f", "62f191cfd6b0888fa0fd3c31597884b7ccdee6c74a255a4afc0f0f25a4ba532d", "b2e58d8678bb66fc00d02047b985cbe5efa1f0e22c71af9684d67fcb1cad940d", "c3ee9ede913d1987b28eeec5de8cc8c0778d1f6e43c4f7ac28c2e5c681571702", "e7e484487cafa71e9c1231740f64bc662b6794ef6ea376c1989074a56cb42c1d", "912e8b04d865dd91f4548849523c91444ac70ff589ba298ce10678a5816ace2d", "2ba9baa6ff79c7727ad1648c1c7fcc4e9943d8b1a2c68f6c1ef1e70d70877510", "e59707ec253abeb04e6cceaf803dd1b69030f7ac8b916059b0d7d60edacbae26", "f36327129c4a66cf7f976b11c0705bf642740bd90055df4ec1540e6b550f5b03", "448025c0ed6a60edd0fa97eb1f84a1f04c8416eb15268b2a89c24a47dee7132b", "08e26120d9d2937b05d58c08aff93266317f19df353258290da4fb068e0af02f", "bb8668525fef05da280502c1353e0c257dce8cfd53beadde87e4366a5a79dc24", "e6f256845d0b8f9177727723857e9b30314cfc753432ca365c0e6b100d68fd22", "642a784417b01858ffed0ccd9b4967a9e7980facdce7667a07b367fabe63d225", "5ebd45b2dc7e010782a4c51a8ae18bad00c35597010a2107cad5041ffab69329", "d73e8c0e36e5588836bc9be4820e108d008f8399e4a9bacb5a452d4850a72d10", "01b81a331bc0c7818812c3848d382551183b35a16d74df5c8c32d561edb74b1c", "403e3cb57be08aef37dcc8af0a93a6ea8064540c8bcdb76fb34875c3d894be03", "6e420bc668f7b2aeee7e719daa3a7a4471bd04e8bcf24a27e4a5ae07e8c44207", "98baf438da4c655b9d92dc9033ae0f5cd7f0efda9b0d1bb894d08f1ce8620a01", "1282dda3446fb157e236155197def0d309eecb9dde8445f599ead69d4f31d916", "6453a3cf73ab5f3bafe645ce69fcdb612526fa66659e564c783c5600fb3a400f", "a8c1bfdbae2f56d10ccaf89887286c7c3256f7bdba21e98ac3c44578926c642c", "34bd74a58df94ae160f90bb64d202908d95b9dd0d89f02cd7e6bc8ddaf11280f", "a7377899f99a93796cd8901e17357403a900570d869fc49afed5e0e8f4bb281e", "63485fb688def0de08ae284fbc0cb6b7d9a6696e9542eb9328d69de33607f902", "6767b23b636e9b89c8b3ac3614fbdf529b6485cb3fc8ae110b705dbcb9e1fe12", "b54c6a95a349be5a1c09e487b4149111c6ccfbdaec5ec6f8ff82fb21ee894113", "604b619329ec489482dcc4af6f5a02f9ed1418f624f900eca143355127406217", "a556c534da5f5549bceb1ba95535dd57af5fd59011772552d5fea78a02e78a11", "34eae6950d3227d848e7e075aecdb65791306156b6503a89406e5802bfd0e117", "a6f3a081dd622f89f0e8703281052ff2a275507214fed44d3813a5027e5c762a"]
      var groupSize = int(groupKeys.len/2)

      # validate the user-supplied membership index
      if rlnRelayMemIndex < uint(0) or rlnRelayMemIndex >= uint(groupSize):
        info "wrong membership index, failed to mount WakuRLNRelay"
      else: 
        # prepare group related inputs from the hardcoded data
        var groupKeyPairs = newSeq[MembershipKeyPair]()
        var groupIDCommitments = newSeq[IDCommitment]()
        for i in 0..groupSize-1:
          groupKeyPairs.add(MembershipKeyPair(idKey: groupKeys[i].hexToByteArray(32), idCommitment: groupKeys[2*i+1].hexToByteArray(32)))
          groupIDCommitments.add(groupKeys[2*i+1].hexToByteArray(32))
        
        # mount rlnrelay
        waitFor node.mountRlnRelay(groupOpt= some(groupIDCommitments), memKeyPairOpt = some(groupKeyPairs[rlnRelayMemIndex]), memIndexOpt= some(rlnRelayMemIndex))

        # check the correct construction of the tree by comparing the calculated root against the expected root
        # no error should happen as it is already captured in the unit tests
        # TODO have added this check to account for unexpected corner cases, will remove it later 
        let 
          root = node.wakuRlnRelay.rlnInstance.getMerkleRoot.value.toHex() 
          expectedRoot = "823d1bb20d78cb748a6e0fd0833623ae8fcaafb284634b8a413b9eb154b71b25"
        if root != expectedRoot:
          err "root mismatch: something went wrong not in Merkle tree construction"
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
  info "Discoverable ENR ", enr = node.enr.toURI()

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
              relayMessages = conf.relay,
              rlnRelayMemIndex = conf.rlnRelayMemIndex) # Indicates if node is capable to relay messages
    
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
    
    # Connect to discovered nodes
    if conf.dnsDiscovery and conf.dnsDiscoveryUrl != "":
      debug "Discovering nodes using Waku DNS discovery", url=conf.dnsDiscoveryUrl

      var nameServers: seq[TransportAddress]
      for ip in conf.dnsDiscoveryNameServers:
        nameServers.add(initTAddress(ip, Port(53))) # Assume all servers use port 53

      let dnsResolver = DnsResolver.new(nameServers)

      proc resolver(domain: string): Future[string] {.async, gcsafe.} =
        trace "resolving", domain=domain
        let resolved = await dnsResolver.resolveTxt(domain)
        return resolved[0] # Use only first answer
      
      var wakuDnsDiscovery = WakuDnsDiscovery.init(conf.dnsDiscoveryUrl,
                                                   resolver)
      if wakuDnsDiscovery.isOk:
        let discoveredPeers = wakuDnsDiscovery.get().findPeers()
        if discoveredPeers.isOk:
          info "Connecting to discovered peers"
          waitFor connectToNodes(node, discoveredPeers.get())
      else:
        warn "Failed to init Waku DNS discovery"

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
