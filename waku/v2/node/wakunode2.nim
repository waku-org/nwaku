{.push raises: [Defect].}

import
  std/[options, tables, strutils, sequtils, os],
  chronos, chronicles, metrics,
  stew/shims/net as stewNet,
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
  ../protocol/waku_rln_relay/waku_rln_relay_types,
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
      # a static list of membership keys 
      # var groupKeyPairs: seq[MembershipKeyPair] = @[MembershipKeyPair(idKey: [byte(221), 202, 14, 182, 32, 213, 16, 12, 104, 98, 3, 228, 56, 58, 255, 19, 133, 254, 167, 191, 28, 123, 174, 89, 155, 224, 169, 23, 32, 170, 160, 15], idCommitment: [byte(188), 40, 2, 168, 203, 137, 86, 46, 223, 185, 0, 204, 83, 108, 239, 97, 212, 184, 253, 223, 166, 63, 172, 89, 160, 181, 77, 16, 29, 83, 180, 3]), MembershipKeyPair(idKey: [105, 53, 42, 250, 11, 68, 121, 183, 34, 146, 90, 70, 90, 29, 129, 234, 221, 36, 9, 174, 181, 53, 106, 66, 79, 197, 59, 94, 206, 16, 179, 25], idCommitment: [85, 178, 42, 250, 182, 200, 109, 20, 184, 140, 129, 45, 175, 6, 248, 147, 33, 14, 185, 175, 254, 178, 195, 208, 65, 228, 148, 58, 235, 36, 210, 13]), MembershipKeyPair(idKey: [85, 191, 208, 234, 16, 203, 65, 209, 121, 3, 158, 142, 139, 246, 83, 28, 94, 158, 102, 166, 163, 150, 131, 63, 146, 60, 112, 130, 27, 241, 213, 24], idCommitment: [224, 14, 51, 10, 122, 26, 58, 107, 98, 32, 198, 21, 40, 78, 64, 216, 137, 35, 18, 69, 240, 120, 45, 187, 156, 129, 85, 113, 249, 224, 166, 30]), MembershipKeyPair(idKey: [174, 78, 6, 112, 8, 128, 108, 118, 110, 67, 228, 123, 199, 109, 159, 245, 255, 90, 143, 204, 209, 46, 102, 192, 63, 74, 85, 127, 63, 190, 228, 26], idCommitment: [9, 212, 73, 104, 136, 14, 86, 83, 215, 3, 131, 202, 179, 157, 28, 244, 66, 34, 23, 206, 5, 54, 139, 136, 92, 77, 127, 144, 89, 152, 249, 9]), MembershipKeyPair(idKey: [76, 90, 213, 30, 164, 117, 41, 169, 207, 10, 118, 199, 234, 188, 197, 239, 133, 118, 64, 98, 12, 70, 75, 154, 184, 104, 73, 109, 240, 157, 9, 20], idCommitment: [189, 211, 159, 239, 46, 31, 104, 33, 20, 229, 217, 66, 52, 210, 126, 248, 224, 164, 180, 65, 115, 198, 179, 146, 56, 7, 154, 249, 248, 247, 104, 25]), MembershipKeyPair(idKey: [216, 94, 46, 87, 235, 228, 103, 224, 253, 52, 163, 70, 214, 112, 224, 97, 34, 125, 69, 171, 211, 165, 52, 7, 72, 188, 188, 17, 20, 52, 119, 46], idCommitment: [39, 144, 167, 149, 110, 143, 57, 167, 45, 192, 160, 74, 158, 97, 160, 67, 181, 58, 135, 18, 109, 112, 41, 52, 101, 51, 43, 192, 97, 159, 59, 27]), MembershipKeyPair(idKey: [93, 184, 57, 150, 250, 79, 195, 224, 175, 186, 181, 9, 9, 87, 64, 200, 213, 11, 9, 168, 215, 82, 84, 182, 107, 229, 240, 85, 114, 76, 219, 13], idCommitment: [74, 172, 63, 130, 106, 238, 157, 40, 218, 83, 151, 220, 147, 242, 191, 200, 141, 69, 23, 4, 91, 164, 114, 76, 15, 110, 133, 119, 190, 170, 58, 47]), MembershipKeyPair(idKey: [129, 150, 171, 0, 174, 188, 147, 90, 1, 12, 76, 182, 179, 69, 109, 136, 168, 2, 146, 64, 197, 21, 237, 255, 122, 148, 234, 57, 217, 15, 206, 3], idCommitment: [4, 123, 226, 60, 79, 95, 95, 222, 177, 7, 79, 196, 125, 241, 176, 66, 226, 42, 129, 170, 105, 36, 229, 228, 14, 140, 194, 35, 166, 151, 207, 31]), MembershipKeyPair(idKey: [254, 243, 137, 132, 53, 4, 250, 182, 237, 180, 240, 139, 152, 32, 66, 109, 49, 227, 57, 27, 19, 212, 203, 233, 177, 195, 109, 164, 225, 69, 55, 6], idCommitment: [52, 151, 122, 35, 69, 67, 56, 253, 244, 108, 121, 85, 7, 182, 67, 59, 76, 180, 4, 78, 86, 215, 137, 91, 5, 209, 253, 104, 131, 91, 228, 31]), MembershipKeyPair(idKey: [226, 43, 170, 93, 7, 200, 168, 20, 235, 96, 175, 232, 37, 117, 118, 98, 145, 40, 178, 196, 231, 127, 167, 6, 242, 112, 161, 232, 5, 129, 54, 43], idCommitment: [89, 159, 193, 114, 110, 146, 176, 140, 111, 76, 66, 241, 172, 92, 10, 166, 138, 112, 67, 77, 62, 121, 17, 176, 13, 138, 247, 48, 176, 108, 192, 46]), MembershipKeyPair(idKey: [229, 55, 206, 248, 210, 173, 113, 82, 220, 126, 106, 44, 79, 118, 128, 209, 33, 221, 165, 168, 233, 22, 45, 212, 93, 180, 111, 101, 158, 22, 173, 47], idCommitment: [50, 223, 211, 209, 154, 151, 85, 64, 229, 251, 174, 16, 88, 28, 249, 82, 172, 217, 95, 47, 22, 97, 250, 71, 218, 124, 198, 130, 123, 188, 242, 20]), MembershipKeyPair(idKey: [37, 15, 127, 70, 30, 203, 102, 72, 210, 130, 14, 208, 133, 205, 38, 176, 118, 77, 115, 205, 148, 58, 156, 51, 24, 196, 254, 23, 249, 252, 146, 44], idCommitment: [91, 129, 156, 147, 67, 222, 21, 240, 185, 237, 23, 4, 85, 228, 148, 253, 9, 140, 175, 163, 148, 154, 62, 85, 69, 182, 99, 245, 220, 24, 165, 25]), MembershipKeyPair(idKey: [152, 166, 126, 237, 119, 183, 158, 103, 21, 119, 194, 36, 92, 234, 229, 222, 224, 182, 168, 41, 193, 1, 108, 224, 75, 198, 62, 31, 45, 23, 127, 47], idCommitment: [77, 17, 115, 36, 162, 8, 227, 175, 216, 156, 63, 106, 218, 214, 20, 185, 253, 135, 100, 239, 105, 93, 60, 195, 7, 94, 183, 29, 115, 51, 83, 11]), MembershipKeyPair(idKey: [92, 190, 65, 186, 229, 106, 247, 205, 115, 46, 168, 47, 194, 200, 81, 44, 35, 203, 171, 61, 254, 64, 16, 158, 39, 68, 40, 50, 181, 190, 145, 11], idCommitment: [157, 166, 84, 102, 154, 198, 174, 235, 135, 181, 223, 201, 223, 78, 23, 120, 71, 169, 94, 251, 173, 250, 155, 87, 223, 189, 217, 6, 11, 130, 52, 45]), MembershipKeyPair(idKey: [25, 42, 60, 213, 232, 193, 116, 106, 81, 215, 129, 196, 196, 37, 181, 245, 182, 180, 29, 136, 198, 126, 74, 205, 155, 228, 191, 175, 121, 24, 174, 11], idCommitment: [16, 201, 41, 53, 198, 209, 0, 143, 107, 221, 155, 134, 247, 232, 114, 222, 24, 54, 110, 243, 198, 10, 89, 208, 117, 102, 81, 66, 89, 4, 136, 19]), MembershipKeyPair(idKey: [255, 243, 12, 43, 204, 119, 161, 251, 212, 196, 186, 139, 85, 141, 247, 136, 4, 255, 71, 93, 89, 47, 91, 177, 36, 211, 59, 236, 26, 206, 203, 18], idCommitment: [15, 208, 136, 240, 134, 167, 183, 2, 44, 9, 46, 254, 89, 215, 157, 241, 107, 31, 113, 180, 6, 98, 95, 96, 136, 137, 186, 2, 49, 113, 207, 2]), MembershipKeyPair(idKey: [89, 128, 83, 74, 9, 200, 82, 244, 83, 26, 14, 118, 187, 220, 234, 70, 79, 86, 118, 28, 171, 49, 87, 18, 164, 165, 91, 0, 168, 45, 187, 29], idCommitment: [13, 217, 25, 109, 208, 45, 50, 186, 237, 67, 205, 136, 82, 184, 243, 213, 55, 12, 206, 86, 159, 132, 176, 57, 121, 51, 2, 242, 111, 96, 45, 42]), MembershipKeyPair(idKey: [59, 59, 126, 18, 182, 185, 87, 195, 76, 33, 52, 29, 160, 73, 183, 190, 38, 211, 239, 50, 136, 160, 226, 213, 26, 150, 233, 71, 137, 213, 217, 35], idCommitment: [58, 13, 64, 157, 70, 144, 119, 67, 84, 86, 75, 214, 155, 238, 244, 10, 186, 147, 184, 108, 143, 212, 191, 11, 51, 37, 7, 237, 190, 58, 76, 5]), MembershipKeyPair(idKey: [222, 21, 239, 181, 236, 78, 244, 71, 204, 117, 110, 153, 139, 58, 163, 175, 97, 227, 71, 157, 162, 168, 152, 225, 87, 141, 45, 106, 60, 237, 13, 20], idCommitment: [37, 137, 110, 227, 207, 192, 230, 105, 169, 115, 151, 48, 201, 186, 211, 37, 68, 173, 20, 187, 21, 46, 67, 181, 136, 109, 35, 4, 15, 120, 232, 12]), MembershipKeyPair(idKey: [66, 14, 101, 117, 136, 218, 150, 254, 148, 145, 222, 79, 26, 63, 68, 181, 145, 224, 105, 100, 180, 116, 217, 147, 18, 231, 146, 209, 21, 75, 138, 10], idCommitment: [44, 103, 1, 250, 216, 2, 90, 174, 52, 83, 129, 23, 32, 169, 225, 75, 19, 197, 126, 37, 244, 121, 146, 146, 54, 184, 140, 82, 59, 115, 82, 16]), MembershipKeyPair(idKey: [151, 87, 25, 151, 189, 155, 17, 192, 54, 142, 97, 161, 2, 136, 218, 137, 195, 174, 97, 2, 39, 95, 109, 142, 129, 167, 116, 23, 72, 31, 209, 19], idCommitment: [43, 120, 19, 22, 48, 161, 249, 199, 18, 41, 253, 111, 254, 126, 54, 64, 195, 132, 247, 12, 103, 101, 93, 191, 240, 142, 204, 238, 175, 64, 34, 20]), MembershipKeyPair(idKey: [91, 31, 120, 218, 50, 128, 230, 217, 94, 233, 25, 106, 13, 221, 154, 104, 77, 67, 183, 193, 5, 149, 252, 246, 5, 235, 243, 39, 88, 18, 170, 8], idCommitment: [239, 95, 35, 25, 117, 166, 127, 224, 241, 76, 94, 230, 71, 119, 60, 139, 142, 94, 215, 128, 30, 17, 238, 247, 10, 138, 95, 33, 73, 140, 140, 4]), MembershipKeyPair(idKey: [202, 7, 231, 12, 149, 108, 196, 238, 231, 247, 64, 152, 2, 11, 86, 246, 158, 81, 110, 222, 2, 231, 109, 66, 66, 100, 188, 99, 39, 128, 106, 39], idCommitment: [139, 232, 20, 25, 186, 140, 15, 76, 99, 211, 180, 198, 209, 24, 154, 134, 84, 94, 61, 183, 216, 165, 139, 3, 165, 76, 186, 208, 215, 90, 36, 23]), MembershipKeyPair(idKey: [198, 77, 14, 13, 170, 177, 249, 30, 155, 15, 147, 119, 8, 250, 34, 157, 69, 245, 98, 133, 225, 19, 26, 67, 188, 166, 196, 175, 239, 247, 206, 33], idCommitment: [252, 242, 230, 62, 143, 32, 111, 6, 39, 186, 51, 176, 254, 78, 173, 27, 137, 235, 180, 199, 62, 226, 118, 104, 231, 210, 86, 134, 159, 153, 71, 13]), MembershipKeyPair(idKey: [72, 138, 37, 94, 20, 3, 133, 180, 221, 25, 41, 83, 84, 146, 234, 61, 47, 183, 124, 237, 9, 176, 168, 128, 52, 79, 75, 10, 200, 104, 21, 23], idCommitment: [135, 236, 43, 223, 209, 176, 163, 255, 77, 124, 101, 67, 188, 209, 252, 191, 150, 61, 106, 227, 95, 68, 18, 47, 200, 199, 248, 70, 233, 120, 38, 47]), MembershipKeyPair(idKey: [136, 254, 195, 95, 243, 77, 175, 33, 30, 101, 23, 205, 185, 73, 48, 217, 117, 242, 156, 205, 147, 200, 130, 54, 170, 165, 94, 67, 69, 226, 217, 12], idCommitment: [224, 50, 109, 5, 143, 167, 136, 242, 155, 246, 30, 154, 105, 71, 240, 193, 147, 94, 52, 181, 69, 100, 255, 131, 230, 220, 223, 139, 223, 224, 105, 33]), MembershipKeyPair(idKey: [238, 180, 123, 105, 110, 41, 189, 204, 171, 42, 179, 163, 246, 47, 207, 120, 61, 119, 238, 219, 127, 160, 174, 138, 30, 61, 18, 81, 184, 169, 135, 25], idCommitment: [31, 178, 216, 236, 103, 153, 149, 250, 20, 120, 27, 41, 0, 87, 9, 18, 167, 55, 164, 246, 69, 163, 28, 55, 150, 250, 218, 154, 185, 144, 165, 47]), MembershipKeyPair(idKey: [244, 157, 249, 243, 42, 242, 202, 215, 24, 205, 212, 121, 222, 107, 62, 105, 164, 143, 94, 23, 73, 4, 74, 170, 114, 25, 203, 57, 38, 180, 94, 37], idCommitment: [199, 113, 219, 25, 63, 151, 154, 177, 136, 105, 21, 80, 210, 80, 161, 161, 185, 87, 29, 23, 223, 152, 229, 227, 107, 221, 72, 170, 237, 13, 117, 17]), MembershipKeyPair(idKey: [196, 26, 233, 153, 214, 130, 246, 45, 173, 125, 132, 32, 199, 208, 217, 237, 54, 18, 53, 219, 233, 129, 221, 120, 11, 18, 229, 195, 189, 249, 153, 40], idCommitment: [232, 173, 84, 142, 88, 57, 129, 80, 17, 254, 84, 41, 123, 167, 87, 235, 136, 25, 226, 62, 35, 222, 250, 52, 61, 146, 186, 195, 104, 10, 199, 19]), MembershipKeyPair(idKey: [28, 200, 95, 35, 208, 28, 48, 79, 28, 18, 252, 101, 71, 150, 181, 57, 45, 27, 30, 61, 37, 156, 102, 171, 110, 88, 221, 71, 177, 34, 14, 29], idCommitment: [110, 144, 160, 184, 233, 200, 99, 97, 15, 120, 207, 78, 114, 54, 155, 165, 231, 80, 140, 165, 222, 144, 217, 181, 183, 159, 107, 157, 109, 210, 224, 38]), MembershipKeyPair(idKey: [171, 225, 12, 4, 151, 253, 58, 94, 40, 117, 143, 142, 61, 190, 101, 74, 169, 212, 147, 29, 49, 240, 53, 59, 237, 249, 147, 241, 223, 176, 29, 12], idCommitment: [73, 79, 229, 113, 41, 255, 94, 181, 155, 16, 15, 188, 212, 193, 127, 239, 231, 137, 99, 59, 197, 94, 65, 254, 138, 246, 153, 23, 186, 24, 132, 6]), MembershipKeyPair(idKey: [72, 55, 210, 219, 20, 121, 187, 110, 233, 197, 20, 79, 94, 152, 39, 166, 244, 127, 46, 239, 245, 28, 91, 0, 152, 98, 57, 224, 66, 185, 231, 15], idCommitment: [46, 51, 184, 17, 182, 133, 63, 170, 144, 9, 174, 56, 174, 45, 34, 129, 6, 244, 141, 247, 61, 137, 152, 169, 151, 251, 96, 182, 104, 57, 1, 18]), MembershipKeyPair(idKey: [13, 126, 199, 13, 182, 185, 71, 9, 69, 59, 84, 89, 164, 132, 147, 214, 94, 15, 147, 117, 250, 67, 207, 242, 75, 182, 89, 133, 5, 247, 144, 7], idCommitment: [216, 191, 78, 156, 118, 173, 177, 159, 6, 180, 182, 91, 214, 142, 66, 133, 15, 141, 35, 207, 13, 13, 110, 92, 246, 228, 222, 207, 226, 75, 162, 20]), MembershipKeyPair(idKey: [186, 248, 227, 145, 126, 52, 244, 246, 248, 220, 194, 136, 252, 245, 232, 229, 248, 94, 221, 62, 41, 86, 33, 101, 91, 56, 1, 215, 135, 240, 140, 30], idCommitment: [46, 153, 15, 12, 252, 46, 116, 45, 98, 95, 182, 234, 1, 165, 41, 71, 172, 129, 220, 23, 197, 69, 50, 105, 53, 104, 244, 177, 11, 155, 64, 35]), MembershipKeyPair(idKey: [224, 176, 130, 209, 166, 243, 225, 179, 67, 112, 94, 151, 89, 15, 28, 156, 44, 220, 25, 185, 13, 7, 151, 188, 114, 70, 106, 246, 122, 145, 21, 21], idCommitment: [141, 132, 126, 153, 248, 13, 102, 69, 84, 219, 243, 52, 238, 61, 82, 213, 167, 63, 123, 56, 32, 50, 253, 245, 97, 2, 150, 201, 117, 43, 140, 9]), MembershipKeyPair(idKey: [111, 72, 35, 34, 78, 52, 145, 250, 214, 24, 102, 163, 82, 196, 212, 137, 98, 65, 116, 166, 171, 52, 249, 140, 118, 255, 77, 172, 86, 46, 254, 37], idCommitment: [154, 18, 56, 117, 33, 59, 56, 204, 217, 89, 241, 26, 162, 246, 84, 213, 228, 197, 5, 37, 58, 114, 168, 216, 61, 153, 112, 203, 118, 193, 157, 16]), MembershipKeyPair(idKey: [8, 150, 163, 18, 111, 167, 127, 243, 20, 178, 35, 85, 62, 41, 74, 139, 147, 61, 119, 17, 129, 120, 102, 148, 57, 36, 120, 19, 67, 223, 178, 30], idCommitment: [167, 241, 156, 61, 99, 185, 1, 224, 197, 157, 118, 248, 128, 147, 231, 88, 132, 166, 98, 45, 159, 247, 241, 85, 34, 135, 152, 154, 1, 194, 199, 39]), MembershipKeyPair(idKey: [104, 112, 188, 98, 116, 247, 212, 101, 116, 81, 60, 183, 252, 166, 54, 205, 160, 86, 0, 241, 53, 20, 223, 37, 88, 127, 253, 67, 249, 18, 44, 23], idCommitment: [183, 38, 233, 208, 215, 227, 81, 56, 45, 134, 102, 52, 50, 73, 220, 64, 254, 195, 17, 84, 222, 116, 165, 73, 157, 47, 16, 197, 120, 17, 137, 9]), MembershipKeyPair(idKey: [88, 93, 171, 24, 123, 43, 99, 96, 183, 158, 214, 47, 141, 163, 47, 92, 159, 116, 33, 73, 11, 133, 154, 70, 214, 230, 70, 235, 205, 37, 218, 8], idCommitment: [226, 241, 95, 125, 131, 39, 59, 90, 107, 137, 194, 11, 216, 225, 156, 81, 112, 61, 128, 8, 221, 103, 60, 70, 184, 244, 175, 167, 161, 115, 243, 18]), MembershipKeyPair(idKey: [157, 245, 151, 157, 73, 55, 18, 90, 101, 100, 63, 165, 166, 153, 4, 54, 253, 248, 40, 229, 214, 167, 149, 43, 121, 177, 39, 220, 118, 205, 249, 34], idCommitment: [49, 247, 114, 63, 10, 142, 104, 136, 55, 116, 7, 91, 1, 45, 65, 41, 246, 81, 5, 247, 51, 4, 83, 94, 227, 253, 9, 238, 35, 72, 45, 15]), MembershipKeyPair(idKey: [96, 237, 137, 137, 177, 107, 207, 49, 5, 135, 27, 193, 167, 19, 187, 70, 139, 213, 121, 209, 226, 243, 110, 77, 110, 221, 149, 159, 0, 197, 48, 21], idCommitment: [78, 2, 2, 174, 168, 111, 255, 3, 28, 151, 143, 28, 220, 15, 133, 19, 157, 194, 16, 249, 133, 33, 40, 231, 185, 187, 207, 225, 42, 92, 183, 5]), MembershipKeyPair(idKey: [160, 168, 194, 167, 178, 179, 8, 211, 103, 188, 70, 251, 136, 209, 56, 71, 136, 54, 166, 74, 32, 201, 20, 215, 108, 18, 205, 198, 55, 198, 228, 15], idCommitment: [118, 121, 42, 17, 198, 224, 249, 122, 176, 71, 65, 156, 165, 9, 129, 237, 26, 162, 83, 129, 43, 113, 72, 3, 177, 27, 92, 85, 45, 26, 29, 29]), MembershipKeyPair(idKey: [15, 186, 55, 72, 43, 235, 242, 10, 145, 75, 132, 53, 45, 53, 23, 82, 206, 209, 237, 28, 247, 4, 35, 155, 54, 47, 222, 31, 246, 161, 33, 7], idCommitment: [80, 85, 57, 61, 254, 75, 105, 149, 132, 44, 127, 9, 218, 171, 145, 30, 145, 180, 15, 63, 117, 127, 158, 209, 31, 184, 0, 126, 0, 140, 226, 21]), MembershipKeyPair(idKey: [196, 138, 5, 207, 40, 93, 6, 22, 101, 92, 132, 210, 1, 255, 123, 110, 3, 99, 39, 104, 74, 7, 140, 242, 130, 170, 69, 103, 82, 32, 99, 37], idCommitment: [206, 105, 222, 185, 190, 119, 156, 110, 17, 205, 243, 78, 253, 135, 196, 248, 75, 219, 136, 73, 130, 36, 208, 129, 89, 254, 33, 80, 140, 103, 218, 7]), MembershipKeyPair(idKey: [31, 232, 203, 238, 75, 131, 248, 35, 95, 192, 202, 88, 89, 182, 137, 90, 190, 230, 72, 1, 115, 94, 124, 181, 197, 87, 151, 111, 207, 54, 82, 37], idCommitment: [52, 239, 90, 150, 129, 219, 62, 182, 191, 183, 216, 118, 104, 41, 121, 22, 50, 176, 46, 239, 166, 138, 221, 155, 23, 215, 172, 78, 194, 53, 221, 17]), MembershipKeyPair(idKey: [201, 110, 200, 203, 196, 144, 125, 32, 40, 190, 73, 56, 114, 175, 89, 0, 103, 227, 77, 59, 128, 29, 150, 139, 178, 89, 232, 138, 218, 86, 173, 41], idCommitment: [50, 150, 47, 122, 98, 17, 93, 129, 250, 138, 90, 92, 198, 176, 169, 94, 13, 226, 202, 162, 141, 8, 212, 49, 209, 157, 235, 180, 115, 226, 65, 8]), MembershipKeyPair(idKey: [0, 124, 69, 92, 163, 104, 140, 212, 49, 200, 149, 140, 207, 252, 183, 229, 141, 79, 157, 216, 253, 234, 42, 209, 114, 39, 38, 176, 74, 220, 248, 24], idCommitment: [128, 13, 96, 213, 231, 116, 127, 190, 167, 51, 179, 109, 242, 127, 156, 137, 218, 164, 134, 64, 216, 135, 174, 4, 53, 181, 247, 209, 63, 146, 87, 14]), MembershipKeyPair(idKey: [56, 103, 112, 110, 53, 251, 140, 49, 91, 176, 174, 49, 38, 166, 216, 22, 95, 181, 24, 180, 218, 191, 143, 84, 89, 215, 194, 210, 8, 76, 99, 2], idCommitment: [236, 160, 85, 218, 145, 206, 16, 125, 168, 3, 240, 200, 150, 80, 173, 87, 208, 193, 218, 38, 109, 17, 165, 126, 49, 44, 228, 81, 214, 140, 224, 10]), MembershipKeyPair(idKey: [95, 149, 86, 123, 222, 53, 97, 97, 33, 251, 55, 145, 65, 157, 107, 132, 208, 49, 48, 197, 82, 171, 175, 164, 57, 52, 29, 219, 171, 101, 189, 2], idCommitment: [201, 208, 160, 91, 38, 156, 253, 224, 37, 113, 137, 163, 131, 182, 90, 109, 186, 213, 212, 8, 241, 178, 196, 206, 139, 205, 242, 33, 243, 217, 217, 38]), MembershipKeyPair(idKey: [188, 212, 215, 0, 22, 128, 208, 187, 220, 247, 183, 70, 133, 21, 243, 111, 139, 187, 150, 122, 50, 55, 156, 253, 177, 174, 48, 39, 121, 86, 234, 14], idCommitment: [155, 164, 36, 3, 68, 197, 37, 22, 115, 228, 47, 15, 203, 103, 230, 80, 235, 213, 177, 41, 58, 242, 141, 223, 212, 98, 212, 28, 18, 50, 118, 6]), MembershipKeyPair(idKey: [77, 79, 76, 97, 135, 4, 237, 85, 70, 166, 73, 10, 250, 156, 204, 59, 42, 47, 193, 81, 195, 73, 166, 136, 15, 133, 159, 55, 77, 109, 126, 4], idCommitment: [192, 159, 98, 219, 142, 197, 15, 59, 42, 34, 223, 68, 112, 114, 210, 113, 33, 159, 178, 158, 33, 15, 111, 58, 14, 217, 210, 199, 173, 169, 12, 33]), MembershipKeyPair(idKey: [209, 144, 198, 103, 94, 122, 103, 133, 19, 102, 22, 62, 37, 52, 14, 33, 116, 134, 100, 38, 242, 198, 239, 114, 2, 20, 174, 47, 185, 62, 223, 10], idCommitment: [167, 104, 235, 175, 212, 183, 33, 69, 167, 156, 103, 144, 105, 10, 134, 121, 17, 56, 215, 224, 1, 78, 234, 110, 68, 235, 22, 157, 196, 236, 16, 12]), MembershipKeyPair(idKey: [53, 60, 86, 232, 108, 18, 241, 211, 96, 225, 64, 227, 244, 7, 128, 18, 141, 83, 222, 13, 19, 24, 50, 86, 28, 111, 11, 8, 40, 244, 169, 19], idCommitment: [227, 197, 186, 202, 183, 223, 34, 5, 212, 36, 144, 42, 55, 240, 201, 188, 240, 37, 140, 66, 233, 200, 181, 191, 125, 26, 68, 231, 253, 235, 11, 13]), MembershipKeyPair(idKey: [93, 230, 150, 246, 101, 68, 231, 175, 141, 56, 95, 111, 104, 169, 155, 53, 131, 49, 134, 211, 94, 211, 127, 21, 255, 120, 75, 135, 56, 50, 11, 18], idCommitment: [162, 148, 180, 217, 250, 89, 252, 0, 127, 105, 8, 129, 188, 39, 59, 105, 169, 202, 84, 18, 115, 242, 177, 100, 29, 35, 198, 85, 207, 126, 118, 26]), MembershipKeyPair(idKey: [255, 229, 39, 117, 138, 219, 34, 179, 9, 169, 245, 101, 224, 234, 69, 131, 114, 185, 35, 95, 204, 104, 78, 195, 138, 2, 33, 121, 210, 211, 153, 14], idCommitment: [163, 209, 218, 81, 14, 102, 55, 88, 200, 134, 230, 137, 240, 30, 252, 15, 113, 6, 149, 202, 144, 182, 1, 34, 170, 244, 13, 200, 15, 70, 109, 39]), MembershipKeyPair(idKey: [127, 202, 9, 209, 125, 99, 177, 4, 157, 90, 136, 130, 49, 138, 206, 111, 40, 162, 85, 131, 182, 70, 205, 11, 123, 152, 221, 33, 55, 82, 46, 39], idCommitment: [18, 114, 59, 105, 0, 208, 246, 110, 245, 83, 215, 79, 140, 13, 198, 205, 15, 73, 161, 108, 83, 173, 252, 248, 129, 128, 82, 58, 133, 128, 61, 48]), MembershipKeyPair(idKey: [226, 248, 242, 242, 129, 247, 64, 44, 53, 253, 86, 177, 144, 196, 90, 203, 212, 86, 144, 221, 204, 145, 100, 156, 194, 106, 240, 86, 186, 14, 95, 38], idCommitment: [209, 203, 153, 50, 127, 116, 123, 104, 254, 90, 196, 49, 94, 179, 191, 82, 98, 72, 131, 229, 185, 227, 89, 122, 44, 177, 76, 83, 56, 252, 208, 14]), MembershipKeyPair(idKey: [79, 151, 99, 95, 9, 216, 200, 101, 231, 105, 51, 15, 71, 26, 60, 23, 23, 13, 9, 3, 227, 235, 138, 121, 206, 159, 168, 148, 11, 2, 7, 41], idCommitment: [210, 169, 230, 231, 124, 248, 49, 167, 43, 44, 248, 125, 237, 135, 206, 193, 3, 214, 28, 154, 218, 161, 132, 226, 180, 212, 49, 116, 213, 214, 180, 1]), MembershipKeyPair(idKey: [45, 52, 111, 53, 134, 189, 162, 175, 45, 147, 225, 157, 231, 75, 50, 4, 87, 200, 145, 170, 38, 28, 209, 208, 222, 133, 72, 169, 206, 17, 34, 25], idCommitment: [132, 147, 186, 136, 88, 75, 157, 106, 106, 255, 251, 73, 74, 97, 209, 132, 236, 220, 212, 13, 55, 234, 77, 88, 203, 38, 148, 197, 101, 49, 155, 1]), MembershipKeyPair(idKey: [198, 214, 143, 115, 91, 43, 101, 146, 29, 121, 77, 108, 172, 38, 115, 33, 96, 183, 205, 107, 213, 8, 182, 176, 229, 20, 176, 70, 34, 236, 212, 14], idCommitment: [193, 230, 23, 16, 143, 154, 161, 206, 167, 3, 221, 135, 82, 67, 144, 220, 223, 245, 48, 61, 239, 229, 174, 18, 213, 141, 101, 163, 199, 50, 54, 41]), MembershipKeyPair(idKey: [148, 149, 121, 104, 27, 229, 28, 198, 246, 48, 199, 143, 38, 152, 206, 81, 17, 4, 52, 49, 92, 46, 79, 225, 235, 82, 16, 193, 133, 217, 68, 16], idCommitment: [116, 30, 188, 128, 45, 175, 244, 83, 240, 221, 207, 114, 248, 109, 34, 39, 55, 90, 21, 198, 137, 215, 119, 179, 52, 220, 79, 140, 36, 177, 78, 41]), MembershipKeyPair(idKey: [100, 10, 20, 54, 209, 168, 179, 2, 100, 92, 133, 92, 230, 68, 232, 217, 33, 62, 40, 143, 61, 31, 127, 204, 145, 135, 5, 8, 152, 24, 7, 16], idCommitment: [52, 238, 99, 24, 176, 224, 123, 69, 156, 163, 171, 60, 83, 143, 48, 106, 81, 253, 229, 214, 186, 81, 41, 21, 92, 115, 252, 97, 131, 129, 229, 17]), MembershipKeyPair(idKey: [163, 136, 95, 60, 181, 202, 72, 161, 134, 186, 87, 228, 92, 97, 182, 83, 186, 163, 202, 107, 62, 183, 172, 209, 228, 197, 24, 29, 145, 93, 99, 4], idCommitment: [102, 61, 114, 85, 9, 191, 211, 126, 40, 241, 12, 123, 56, 38, 7, 10, 63, 111, 219, 127, 206, 181, 108, 88, 124, 174, 84, 165, 247, 210, 33, 5]), MembershipKeyPair(idKey: [208, 160, 13, 36, 87, 66, 193, 5, 204, 147, 172, 106, 129, 160, 69, 228, 195, 160, 178, 141, 232, 207, 80, 37, 166, 55, 230, 242, 231, 100, 59, 41], idCommitment: [52, 228, 83, 33, 108, 180, 7, 76, 109, 179, 216, 163, 26, 49, 142, 65, 190, 177, 192, 22, 116, 224, 119, 5, 105, 119, 251, 145, 225, 89, 80, 34]), MembershipKeyPair(idKey: [116, 181, 229, 206, 4, 169, 154, 30, 176, 21, 21, 63, 182, 58, 125, 0, 210, 240, 169, 202, 119, 34, 177, 105, 67, 26, 248, 129, 17, 24, 171, 44], idCommitment: [232, 165, 180, 119, 18, 39, 54, 250, 85, 45, 69, 213, 208, 8, 122, 202, 253, 251, 250, 214, 209, 169, 153, 109, 198, 166, 85, 114, 76, 215, 209, 38]), MembershipKeyPair(idKey: [64, 253, 66, 161, 32, 7, 22, 199, 211, 24, 35, 128, 51, 86, 180, 215, 81, 176, 249, 174, 180, 168, 246, 191, 26, 53, 84, 170, 53, 179, 61, 21], idCommitment: [2, 221, 167, 241, 186, 121, 252, 67, 105, 64, 176, 180, 190, 116, 46, 13, 238, 19, 31, 226, 192, 87, 75, 106, 158, 179, 103, 206, 209, 64, 59, 25]), MembershipKeyPair(idKey: [195, 226, 190, 34, 86, 42, 29, 173, 217, 136, 154, 176, 255, 51, 191, 193, 46, 248, 98, 46, 70, 200, 130, 165, 131, 93, 158, 139, 141, 95, 225, 22], idCommitment: [134, 6, 146, 123, 241, 83, 144, 43, 107, 203, 10, 83, 80, 52, 234, 180, 116, 38, 40, 133, 124, 189, 144, 130, 88, 217, 51, 55, 220, 237, 189, 14]), MembershipKeyPair(idKey: [180, 69, 253, 153, 78, 35, 175, 149, 149, 35, 193, 171, 127, 92, 77, 77, 43, 205, 2, 188, 160, 54, 157, 49, 193, 56, 75, 15, 36, 37, 168, 4], idCommitment: [141, 7, 80, 62, 126, 105, 27, 250, 102, 152, 91, 191, 225, 122, 190, 148, 149, 198, 99, 180, 164, 132, 97, 75, 242, 227, 97, 201, 183, 209, 58, 40]), MembershipKeyPair(idKey: [207, 159, 136, 197, 0, 125, 107, 95, 167, 224, 161, 74, 226, 23, 39, 132, 155, 117, 160, 115, 56, 132, 187, 164, 96, 245, 192, 180, 145, 155, 119, 47], idCommitment: [35, 36, 89, 28, 51, 31, 22, 179, 15, 224, 247, 60, 95, 157, 14, 104, 30, 171, 124, 187, 82, 218, 86, 166, 232, 152, 80, 44, 116, 150, 67, 22]), MembershipKeyPair(idKey: [61, 18, 173, 128, 182, 5, 53, 83, 189, 134, 160, 152, 79, 50, 168, 151, 211, 150, 80, 171, 138, 101, 206, 132, 36, 78, 124, 249, 63, 11, 235, 30], idCommitment: [57, 223, 244, 195, 24, 231, 156, 186, 9, 219, 98, 121, 147, 189, 21, 214, 248, 209, 211, 8, 243, 51, 45, 209, 24, 98, 229, 92, 179, 27, 63, 7]), MembershipKeyPair(idKey: [177, 255, 178, 146, 78, 11, 201, 15, 67, 156, 124, 183, 223, 46, 241, 142, 227, 10, 129, 198, 1, 115, 30, 118, 72, 16, 233, 117, 234, 173, 58, 34], idCommitment: [184, 250, 49, 16, 181, 189, 65, 38, 39, 59, 223, 130, 170, 38, 169, 119, 150, 156, 137, 141, 105, 2, 54, 94, 215, 134, 216, 66, 8, 162, 236, 0]), MembershipKeyPair(idKey: [17, 149, 210, 236, 16, 2, 148, 181, 250, 222, 55, 232, 15, 224, 34, 79, 43, 161, 158, 105, 253, 233, 170, 128, 155, 126, 138, 253, 41, 164, 160, 25], idCommitment: [187, 53, 19, 218, 174, 7, 91, 13, 197, 73, 101, 85, 246, 177, 174, 203, 61, 65, 159, 23, 82, 73, 87, 239, 18, 112, 110, 243, 121, 224, 94, 29]), MembershipKeyPair(idKey: [65, 40, 58, 164, 203, 131, 207, 226, 36, 153, 253, 96, 107, 92, 177, 22, 206, 123, 164, 161, 45, 86, 122, 188, 46, 159, 55, 32, 210, 46, 248, 37], idCommitment: [10, 180, 121, 120, 223, 22, 142, 204, 79, 216, 204, 94, 166, 18, 166, 128, 251, 193, 246, 100, 60, 43, 34, 111, 156, 189, 104, 190, 214, 52, 105, 4]), MembershipKeyPair(idKey: [71, 59, 30, 26, 184, 7, 62, 248, 68, 175, 35, 45, 97, 124, 226, 90, 34, 62, 33, 90, 44, 207, 8, 40, 69, 201, 78, 49, 245, 11, 37, 22], idCommitment: [240, 212, 152, 243, 105, 8, 165, 48, 97, 182, 248, 239, 174, 121, 90, 23, 10, 183, 69, 53, 6, 39, 90, 180, 26, 127, 138, 27, 84, 217, 243, 18]), MembershipKeyPair(idKey: [222, 42, 77, 42, 54, 182, 144, 11, 238, 136, 91, 211, 127, 224, 84, 86, 171, 221, 187, 143, 174, 165, 57, 249, 116, 215, 104, 223, 239, 153, 137, 30], idCommitment: [123, 31, 97, 200, 38, 131, 26, 177, 143, 4, 120, 61, 181, 141, 64, 60, 87, 26, 77, 130, 181, 174, 206, 143, 164, 115, 21, 28, 2, 70, 232, 2]), MembershipKeyPair(idKey: [94, 139, 82, 68, 82, 206, 252, 26, 205, 182, 132, 8, 65, 141, 188, 158, 240, 168, 19, 11, 141, 115, 243, 82, 152, 204, 243, 15, 170, 33, 195, 12], idCommitment: [68, 134, 168, 30, 143, 38, 197, 146, 42, 114, 77, 103, 215, 84, 135, 36, 18, 170, 117, 17, 91, 168, 222, 219, 162, 235, 70, 222, 159, 150, 230, 30]), MembershipKeyPair(idKey: [129, 208, 247, 199, 85, 119, 239, 200, 10, 94, 117, 217, 182, 232, 200, 225, 10, 70, 204, 216, 82, 180, 11, 138, 23, 59, 123, 155, 236, 1, 104, 11], idCommitment: [64, 180, 112, 55, 139, 50, 183, 122, 31, 180, 91, 220, 2, 23, 193, 14, 67, 77, 152, 173, 222, 101, 198, 197, 245, 74, 77, 80, 92, 17, 239, 2]), MembershipKeyPair(idKey: [171, 32, 243, 35, 154, 218, 64, 173, 50, 108, 232, 55, 233, 216, 28, 91, 198, 11, 1, 57, 10, 13, 68, 191, 224, 134, 21, 149, 5, 118, 24, 0], idCommitment: [109, 186, 35, 130, 53, 102, 197, 16, 97, 123, 222, 113, 191, 175, 142, 142, 182, 76, 34, 162, 75, 84, 226, 73, 155, 206, 241, 52, 10, 40, 21, 20]), MembershipKeyPair(idKey: [26, 243, 131, 36, 167, 36, 85, 48, 169, 51, 16, 129, 211, 42, 151, 170, 70, 52, 3, 173, 120, 196, 93, 178, 132, 62, 96, 177, 215, 51, 63, 44], idCommitment: [72, 11, 242, 197, 70, 240, 85, 141, 99, 65, 254, 117, 4, 212, 233, 192, 8, 166, 210, 250, 166, 120, 45, 201, 216, 202, 161, 93, 196, 245, 227, 26]), MembershipKeyPair(idKey: [102, 211, 28, 251, 80, 23, 177, 16, 90, 172, 179, 105, 251, 86, 173, 61, 191, 154, 133, 11, 50, 149, 205, 200, 80, 147, 8, 171, 188, 223, 4, 6], idCommitment: [142, 49, 21, 211, 235, 118, 149, 45, 73, 186, 23, 121, 68, 114, 184, 228, 206, 191, 37, 8, 245, 46, 185, 87, 227, 73, 29, 43, 187, 139, 89, 0]), MembershipKeyPair(idKey: [28, 134, 20, 254, 141, 184, 91, 102, 76, 244, 53, 19, 175, 90, 17, 111, 250, 65, 15, 194, 243, 96, 119, 85, 28, 189, 22, 51, 160, 204, 191, 2], idCommitment: [78, 127, 197, 11, 8, 154, 222, 118, 28, 35, 242, 129, 239, 39, 117, 115, 85, 96, 124, 178, 89, 230, 83, 251, 36, 61, 47, 158, 148, 125, 24, 20]), MembershipKeyPair(idKey: [139, 96, 209, 148, 54, 237, 123, 147, 163, 223, 172, 105, 137, 21, 67, 230, 26, 252, 51, 138, 202, 239, 155, 171, 195, 191, 110, 10, 215, 33, 226, 37], idCommitment: [88, 157, 182, 253, 166, 160, 184, 235, 201, 230, 17, 255, 84, 193, 81, 159, 151, 224, 41, 78, 149, 10, 187, 227, 26, 106, 83, 131, 181, 161, 60, 14]), MembershipKeyPair(idKey: [105, 1, 104, 3, 18, 233, 127, 145, 32, 152, 197, 54, 171, 146, 77, 31, 254, 157, 90, 65, 226, 38, 238, 159, 175, 37, 219, 161, 153, 102, 195, 45], idCommitment: [189, 43, 38, 128, 226, 166, 170, 70, 128, 92, 180, 64, 57, 158, 90, 198, 173, 1, 117, 90, 99, 82, 44, 254, 7, 219, 199, 18, 87, 89, 130, 35]), MembershipKeyPair(idKey: [206, 2, 199, 15, 33, 212, 96, 14, 27, 27, 182, 19, 80, 173, 170, 27, 222, 175, 22, 188, 65, 156, 100, 231, 93, 65, 200, 226, 100, 20, 189, 44], idCommitment: [247, 65, 180, 239, 219, 166, 80, 207, 22, 80, 137, 26, 17, 177, 189, 52, 140, 101, 130, 180, 42, 105, 232, 185, 201, 22, 246, 64, 39, 48, 224, 46]), MembershipKeyPair(idKey: [189, 81, 241, 35, 160, 3, 146, 83, 179, 137, 64, 157, 222, 116, 95, 159, 14, 26, 134, 89, 21, 222, 15, 214, 144, 36, 18, 185, 163, 152, 98, 30], idCommitment: [56, 169, 244, 150, 221, 198, 66, 253, 224, 137, 30, 98, 186, 49, 234, 172, 95, 147, 192, 146, 236, 224, 31, 217, 191, 4, 132, 173, 140, 241, 37, 28]), MembershipKeyPair(idKey: [3, 153, 163, 93, 93, 120, 162, 236, 225, 124, 145, 32, 131, 254, 120, 113, 5, 71, 5, 156, 184, 65, 211, 29, 46, 63, 61, 95, 55, 35, 49, 9], idCommitment: [239, 98, 32, 168, 59, 50, 28, 5, 15, 73, 103, 94, 123, 75, 27, 122, 201, 111, 94, 110, 123, 49, 133, 247, 117, 152, 103, 168, 139, 96, 85, 21]), MembershipKeyPair(idKey: [155, 186, 228, 239, 253, 67, 166, 236, 252, 141, 135, 188, 84, 237, 183, 199, 216, 54, 44, 40, 106, 142, 195, 160, 6, 90, 30, 243, 178, 47, 93, 27], idCommitment: [51, 251, 36, 80, 242, 127, 120, 55, 51, 253, 220, 66, 214, 186, 80, 159, 107, 47, 76, 24, 42, 133, 90, 55, 4, 8, 173, 208, 178, 55, 90, 3]), MembershipKeyPair(idKey: [1, 84, 120, 81, 118, 125, 12, 169, 38, 102, 212, 78, 162, 190, 220, 217, 248, 98, 12, 243, 239, 230, 148, 117, 152, 151, 132, 149, 27, 250, 178, 41], idCommitment: [180, 157, 197, 112, 24, 94, 40, 18, 13, 240, 187, 225, 191, 229, 48, 160, 206, 68, 147, 132, 109, 17, 230, 132, 107, 163, 244, 219, 60, 82, 176, 14]), MembershipKeyPair(idKey: [195, 137, 115, 28, 87, 239, 199, 246, 183, 138, 253, 173, 38, 244, 22, 81, 62, 94, 140, 93, 117, 194, 155, 44, 213, 136, 37, 130, 93, 153, 172, 15], idCommitment: [6, 252, 128, 165, 217, 161, 74, 38, 80, 165, 41, 196, 7, 137, 154, 58, 169, 104, 185, 9, 121, 78, 219, 144, 148, 175, 151, 75, 63, 223, 126, 9]), MembershipKeyPair(idKey: [215, 106, 195, 187, 60, 2, 158, 229, 233, 233, 5, 166, 194, 12, 20, 74, 175, 247, 88, 83, 39, 215, 210, 195, 44, 102, 103, 109, 85, 104, 166, 36], idCommitment: [229, 153, 90, 7, 235, 65, 227, 50, 243, 28, 60, 70, 77, 171, 29, 173, 237, 176, 212, 16, 229, 24, 111, 250, 205, 222, 41, 13, 135, 7, 236, 2]), MembershipKeyPair(idKey: [102, 8, 47, 109, 235, 184, 179, 76, 228, 247, 254, 81, 105, 181, 52, 149, 46, 47, 48, 120, 197, 155, 187, 222, 168, 166, 90, 89, 49, 68, 37, 38], idCommitment: [141, 15, 166, 182, 23, 82, 117, 216, 64, 90, 239, 105, 8, 218, 59, 163, 9, 142, 1, 70, 168, 31, 80, 244, 19, 26, 148, 115, 253, 61, 240, 13]), MembershipKeyPair(idKey: [105, 167, 45, 50, 79, 17, 39, 71, 143, 81, 222, 196, 182, 81, 177, 190, 32, 159, 240, 1, 102, 37, 121, 242, 193, 166, 96, 8, 139, 0, 51, 35], idCommitment: [164, 254, 141, 52, 69, 71, 74, 88, 226, 71, 232, 196, 202, 83, 52, 105, 17, 136, 90, 32, 210, 31, 47, 165, 78, 169, 103, 169, 243, 140, 241, 20]), MembershipKeyPair(idKey: [95, 63, 81, 2, 253, 87, 253, 56, 246, 148, 244, 250, 18, 66, 6, 120, 161, 38, 216, 249, 147, 7, 25, 196, 177, 228, 93, 242, 129, 19, 145, 29], idCommitment: [47, 97, 100, 218, 234, 157, 149, 161, 252, 111, 239, 243, 78, 248, 206, 94, 203, 205, 26, 15, 226, 173, 84, 3, 190, 7, 223, 94, 102, 253, 149, 6]), MembershipKeyPair(idKey: [180, 165, 135, 131, 56, 40, 158, 39, 164, 172, 204, 191, 101, 4, 71, 195, 80, 186, 240, 3, 180, 25, 167, 229, 168, 223, 34, 211, 180, 173, 137, 43], idCommitment: [152, 100, 20, 95, 189, 96, 207, 10, 244, 121, 223, 22, 183, 169, 219, 174, 26, 9, 225, 14, 77, 247, 227, 104, 125, 118, 47, 34, 166, 64, 129, 0]), MembershipKeyPair(idKey: [0, 253, 138, 186, 78, 17, 20, 251, 234, 152, 176, 37, 46, 160, 115, 27, 8, 205, 190, 128, 27, 146, 209, 142, 85, 33, 206, 12, 236, 98, 45, 19], idCommitment: [28, 220, 171, 205, 238, 143, 93, 95, 77, 230, 43, 89, 203, 228, 126, 211, 147, 90, 102, 31, 7, 214, 72, 169, 223, 203, 53, 181, 164, 127, 214, 41]), MembershipKeyPair(idKey: [88, 49, 213, 165, 79, 141, 15, 241, 186, 196, 48, 180, 103, 214, 6, 135, 72, 227, 127, 152, 192, 231, 57, 59, 77, 81, 50, 44, 53, 171, 144, 11], idCommitment: [60, 9, 24, 109, 13, 68, 137, 23, 163, 247, 100, 46, 50, 208, 87, 198, 145, 115, 130, 70, 134, 171, 16, 7, 0, 122, 225, 231, 22, 170, 47, 10]), MembershipKeyPair(idKey: [249, 96, 141, 186, 52, 246, 47, 144, 188, 59, 34, 194, 122, 65, 127, 27, 120, 158, 247, 248, 103, 218, 23, 230, 153, 79, 98, 126, 243, 103, 153, 12], idCommitment: [87, 169, 100, 214, 2, 202, 4, 85, 163, 34, 24, 140, 175, 118, 7, 46, 17, 100, 34, 186, 15, 36, 71, 62, 95, 157, 92, 117, 42, 69, 105, 1]), MembershipKeyPair(idKey: [59, 174, 223, 85, 201, 117, 105, 139, 144, 88, 44, 44, 200, 213, 231, 80, 110, 8, 128, 241, 158, 43, 231, 145, 28, 247, 96, 75, 250, 185, 11, 1], idCommitment: [198, 166, 244, 191, 118, 122, 43, 38, 78, 135, 38, 51, 129, 12, 58, 97, 126, 174, 208, 61, 53, 151, 45, 93, 30, 52, 95, 231, 211, 12, 57, 21]), MembershipKeyPair(idKey: [246, 55, 47, 91, 67, 17, 48, 163, 137, 130, 164, 56, 147, 213, 69, 11, 100, 150, 200, 170, 138, 98, 70, 77, 70, 60, 65, 115, 12, 214, 80, 29], idCommitment: [29, 207, 59, 132, 35, 30, 46, 97, 127, 117, 164, 203, 236, 247, 120, 5, 142, 126, 245, 186, 252, 201, 138, 183, 34, 208, 96, 39, 193, 103, 239, 18]), MembershipKeyPair(idKey: [78, 109, 3, 169, 80, 185, 8, 139, 226, 240, 33, 119, 150, 8, 37, 199, 114, 214, 129, 1, 3, 134, 218, 221, 161, 155, 122, 126, 146, 151, 15, 41], idCommitment: [85, 38, 191, 202, 230, 92, 169, 227, 45, 225, 104, 214, 39, 66, 203, 156, 116, 224, 111, 98, 177, 71, 114, 42, 158, 87, 245, 136, 206, 73, 119, 17]), MembershipKeyPair(idKey: [60, 237, 54, 210, 122, 32, 190, 93, 50, 70, 125, 253, 242, 191, 80, 143, 253, 19, 63, 6, 15, 40, 182, 48, 203, 171, 83, 38, 82, 122, 98, 2], idCommitment: [183, 148, 237, 74, 166, 138, 124, 232, 253, 63, 71, 249, 23, 70, 102, 59, 39, 205, 67, 37, 130, 24, 12, 22, 12, 178, 161, 205, 150, 252, 26, 48])]
      # var groupIDCommitment: seq[IDCommitment] = groupKeyPairs.filterIt(it.idCommitment)
      # let index = uint32(0)
      # waitFor mountRlnRelay(node, groupOpt= some(groupIDCommitment), memKeyPairOpt = some(groupKeyPairs[index]), memIndexOpt= some(index))
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
