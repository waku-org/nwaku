when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[hashes, options, sugar, tables, strutils, sequtils, os],
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
  libp2p/protocols/rendezvous,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport
import
  ../waku_core,
  ../waku_core/topics/sharding,
  ../waku_relay,
  ../waku_archive,
  ../waku_store,
  ../waku_store/client as store_client,
  ../waku_filter as legacy_filter,  #TODO: support for legacy filter protocol will be removed
  ../waku_filter/client as legacy_filter_client, #TODO: support for legacy filter protocol will be removed
  ../waku_filter_v2,
  ../waku_filter_v2/client as filter_client,
  ../waku_lightpush,
  ../waku_metadata,
  ../waku_lightpush/client as lightpush_client,
  ../waku_enr,
  ../waku_dnsdisc,
  ../waku_peer_exchange,
  ../waku_rln_relay,
  ./config,
  ./peer_manager


declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicHistogram waku_histogram_message_size, "message size histogram in kB",
  buckets = [0.0, 5.0, 15.0, 50.0, 100.0, 300.0, 700.0, 1000.0, Inf]

declarePublicGauge waku_version, "Waku version info (in git describe format)", ["version"]
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]
declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_px_peers, "number of peers (in the node's peerManager) supporting the peer exchange protocol"

logScope:
  topics = "waku node"

# TODO: Move to application instance (e.g., `WakuNode2`)
# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

# Default Waku Filter Timeout
const WakuFilterTimeout: Duration = 1.days

const WakuNodeVersionString* = "version / git commit hash: " & git_version

# key and crypto modules different
type
  # TODO: Move to application instance (e.g., `WakuNode2`)
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
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    wakuFilterLegacy*: legacy_filter.WakuFilterLegacy #TODO: support for legacy filter protocol will be removed
    wakuFilterClientLegacy*: legacy_filter_client.WakuFilterClientLegacy #TODO: support for legacy filter protocol will be removed
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    wakuMetadata*: WakuMetadata
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: ref rand.HmacDrbgContext
    rendezvous*: RendezVous
    announcedAddresses* : seq[MultiAddress]
    started*: bool # Indicates that node has started listening
    topicSubscriptionQueue*: AsyncEventQueue[SubscriptionEvent]
    contentTopicHandlers: Table[ContentTopic, TopicHandler]

proc getAutonatService*(rng: ref HmacDrbgContext): AutonatService =
  ## AutonatService request other peers to dial us back
  ## flagging us as Reachable or NotReachable.
  ## minConfidence is used as threshold to determine the state.
  ## If maxQueueSize > numPeersToAsk past samples are considered
  ## in the calculation.
  let autonatService = AutonatService.new(
    autonatClient = AutonatClient.new(),
    rng = rng,
    scheduleInterval = Opt.some(chronos.seconds(120)),
    askNewConnectedPeers = false,
    numPeersToAsk = 3,
    maxQueueSize = 3,
    minConfidence = 0.7)

  proc statusAndConfidenceHandler(networkReachability: NetworkReachability,
                                  confidence: Opt[float]):
                                  Future[void]  {.gcsafe, async.} =
    if confidence.isSome():
      info "Peer reachability status", networkReachability=networkReachability, confidence=confidence.get()

  autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

  return autonatService

proc new*(T: type WakuNode,
          netConfig: NetConfig,
          enr: enr.Record,
          switch: Switch,
          peerManager: PeerManager,
          # TODO: make this argument required after tests are updated
          rng: ref HmacDrbgContext = crypto.newRng()
          ): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  info "Initializing networking", addrs= $netConfig.announcedAddresses

  let queue = newAsyncEventQueue[SubscriptionEvent](30)

  let node = WakuNode(
    peerManager: peerManager,
    switch: switch,
    rng: rng,
    enr: enr,
    announcedAddresses: netConfig.announcedAddresses,
    topicSubscriptionQueue: queue
  )

  # mount metadata protocol
  let metadata = WakuMetadata.new(netConfig.clusterId, queue)
  node.switch.mount(metadata, protocolMatcher(WakuMetadataCodec))
  node.wakuMetadata = metadata
  peerManager.wakuMetadata = metadata

  return node

proc peerInfo*(node: WakuNode): PeerInfo =
  node.switch.peerInfo

proc peerId*(node: WakuNode): PeerId =
  node.peerInfo.peerId

# TODO: Move to application instance (e.g., `WakuNode2`)
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
  # NOTE Connects to the node without a give protocol, which automatically creates streams for relay
  await peer_manager.connectToNodes(node.peerManager, nodes, source=source)


## Waku relay

proc registerRelayDefaultHandler(node: WakuNode, topic: PubsubTopic) =
  if node.wakuRelay.isSubscribed(topic):
    return

  proc traceHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    trace "waku.relay received",
      peerId=node.peerId,
      pubsubTopic=topic,
      hash=topic.computeMessageHash(msg).to0xHex(),
      receivedTime=getNowInNanosecondTime(),
      payloadSizeBytes=msg.payload.len

    let msgSizeKB = msg.payload.len/1000

    waku_node_messages.inc(labelValues = ["relay"])
    waku_histogram_message_size.observe(msgSizeKB)

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuFilter.isNil():
      return

    await node.wakuFilter.handleMessage(topic, msg)

    ##TODO: Support for legacy filter will be removed
    if node.wakuFilterLegacy.isNil():
      return

    await node.wakuFilterLegacy.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuArchive.isNil():
      return

    await node.wakuArchive.handleMessage(topic, msg)


  let defaultHandler = proc(topic: PubsubTopic, msg: WakuMessage): Future[void] {.async, gcsafe.} =
    await traceHandler(topic, msg)
    await filterHandler(topic, msg)
    await archiveHandler(topic, msg)

  discard node.wakuRelay.subscribe(topic, defaultHandler)

proc subscribe*(node: WakuNode, subscription: SubscriptionEvent, handler = none(WakuRelayHandler)) =
  ## Subscribes to a PubSub or Content topic. Triggers handler when receiving messages on
  ## this topic. WakuRelayHandler is a method that takes a topic and a Waku message.

  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return

  let (pubsubTopic, contentTopicOp) =
    case subscription.kind:
      of ContentSub:
        let shard = getShard((subscription.topic)).valueOr:
          error "Autosharding error", error=error
          return

        (shard, some(subscription.topic))
      of PubsubSub: (subscription.topic, none(ContentTopic))
      else: return

  if contentTopicOp.isSome() and node.contentTopicHandlers.hasKey(contentTopicOp.get()):
    error "Invalid API call to `subscribe`. Was already subscribed"
    return

  debug "subscribe", pubsubTopic=pubsubTopic

  node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: pubsubTopic))
  node.registerRelayDefaultHandler(pubsubTopic)

  if handler.isSome():
    let wrappedHandler = node.wakuRelay.subscribe(pubsubTopic, handler.get())

    if contentTopicOp.isSome():
      node.contentTopicHandlers[contentTopicOp.get()] = wrappedHandler

proc unsubscribe*(node: WakuNode, subscription: SubscriptionEvent) =
  ## Unsubscribes from a specific PubSub or Content topic.

  if node.wakuRelay.isNil():
    error "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return

  let (pubsubTopic, contentTopicOp) =
    case subscription.kind:
      of ContentUnsub:
        let shard = getShard((subscription.topic)).valueOr:
          error "Autosharding error", error=error
          return

        (shard, some(subscription.topic))
      of PubsubUnsub: (subscription.topic, none(ContentTopic))
      else: return

  if not node.wakuRelay.isSubscribed(pubsubTopic):
    error "Invalid API call to `unsubscribe`. Was not subscribed"
    return

  if contentTopicOp.isSome():
    # Remove this handler only
    var handler: TopicHandler
    if node.contentTopicHandlers.pop(contentTopicOp.get(), handler):
      debug "unsubscribe", contentTopic=contentTopicOp.get()
      node.wakuRelay.unsubscribe(pubsubTopic, handler)

  if contentTopicOp.isNone() or node.wakuRelay.topics.getOrDefault(pubsubTopic).len == 1:
    # Remove all handlers
    debug "unsubscribe", pubsubTopic=pubsubTopic
    node.wakuRelay.unsubscribeAll(pubsubTopic)
    node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: pubsubTopic))

proc publish*(
  node: WakuNode,
  pubsubTopicOp: Option[PubsubTopic],
  message: WakuMessage
  ) {.async, gcsafe.} =
  ## Publish a `WakuMessage`. Pubsub topic contains; none, a named or static shard.
  ## `WakuMessage` should contain a `contentTopic` field for light node functionality.
  ## It is also used to determine the shard.

  if node.wakuRelay.isNil():
    error "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    # TODO: Improve error handling
    return

  let pubsubTopic = pubsubTopicOp.valueOr:
    getShard(message.contentTopic).valueOr:
      error "Autosharding error", error=error
      return

  #TODO instead of discard return error when 0 peers received the message
  discard await node.wakuRelay.publish(pubsubTopic, message)

  trace "waku.relay published",
    peerId=node.peerId,
    pubsubTopic=pubsubTopic,
    hash=pubsubTopic.computeMessageHash(message).to0xHex(),
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
                 pubsubTopics: seq[string] = @[],
                 peerExchangeHandler = none(RoutingRecordsHandler)) {.async, gcsafe.} =
  if not node.wakuRelay.isNil():
    error "wakuRelay already mounted, skipping"
    return

  ## The default relay topics is the union of all configured topics plus default PubsubTopic(s)
  info "mounting relay protocol"

  let initRes = WakuRelay.new(node.switch)
  if initRes.isErr():
    error "failed mounting relay protocol", error=initRes.error
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
  for pubsubTopic in pubsubTopics:
    node.subscribe((kind: PubsubSub, topic: pubsubTopic))

## Waku filter

proc mountFilter*(node: WakuNode, filterTimeout: Duration = WakuFilterTimeout)
                 {.async, raises: [Defect, LPError]} =
  info "mounting filter protocol"
  node.wakuFilter = WakuFilter.new(node.peerManager)
  node.wakuFilterLegacy = WakuFilterLegacy.new(node.peerManager, node.rng, filterTimeout) #TODO: remove legacy

  if node.started:
    await node.wakuFilter.start()
    await node.wakuFilterLegacy.start() #TODO: remove legacy

  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterSubscribeCodec))
  node.switch.mount(node.wakuFilterLegacy, protocolMatcher(WakuLegacyFilterCodec)) #TODO: remove legacy

proc filterHandleMessage*(node: WakuNode,
                          pubsubTopic: PubsubTopic,
                          message: WakuMessage)
                          {.async.}=

  if node.wakuFilter.isNil() or node.wakuFilterLegacy.isNil():
    error "cannot handle filter message", error="waku filter is nil"
    return

  await allFutures(node.wakuFilter.handleMessage(pubsubTopic, message),
                   node.wakuFilterLegacy.handleMessage(pubsubTopic, message) #TODO: remove legacy
                  )

proc mountFilterClient*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  ## Mounting both filter clients v1 - legacy and v2.
  ## Giving option for application level to chose btw own push message handling or
  ## rely on node provided cache. - This only applies for v2 filter client
  info "mounting filter client"

  node.wakuFilterClientLegacy = WakuFilterClientLegacy.new(node.peerManager, node.rng)
  node.wakuFilterClient = WakuFilterClient.new(node.peerManager, node.rng)

  if node.started:
    await allFutures(node.wakuFilterClientLegacy.start(), node.wakuFilterClient.start())

  node.switch.mount(node.wakuFilterClient, protocolMatcher(WakuFilterSubscribeCodec))
  node.switch.mount(node.wakuFilterClientLegacy, protocolMatcher(WakuLegacyFilterCodec))

proc legacyFilterSubscribe*(node: WakuNode,
                            pubsubTopic: Option[PubsubTopic],
                            contentTopics: ContentTopic|seq[ContentTopic],
                            handler: FilterPushHandler,
                            peer: RemotePeerInfo|string)
                            {.async, gcsafe, raises: [Defect, ValueError].} =

  ## Registers for messages that match a specific filter.
  ## Triggers the handler whenever a message is received.
  if node.wakuFilterClientLegacy.isNil():
    error "cannot register filter subscription to topic", error="waku legacy filter client is not set up"
    return

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "Couldn't parse the peer info properly", error = remotePeerRes.error
    return

  let remotePeer = remotePeerRes.value

  # Add handler wrapper to store the message when pushed, when relay is disabled and filter enabled
  # TODO: Move this logic to wakunode2 app
  # FIXME: This part needs refactoring. It seems possible that in special cases archiver will store same message multiple times.
  let handlerWrapper: FilterPushHandler =
        if node.wakuRelay.isNil() and not node.wakuStore.isNil():
          proc(pubsubTopic: string, message: WakuMessage) {.async, gcsafe, closure.} =
            await allFutures(node.wakuArchive.handleMessage(pubSubTopic, message),
                             handler(pubsubTopic, message))
        else:
          handler

  if pubsubTopic.isSome():
    info "registering legacy filter subscription to content",
      pubsubTopic=pubsubTopic.get(),
      contentTopics=contentTopics,
      peer=remotePeer.peerId

    let res = await node.wakuFilterClientLegacy.subscribe(pubsubTopic.get(),
                                                          contentTopics,
                                                          handlerWrapper,
                                                          peer=remotePeer)

    if res.isOk():
      info "subscribed to topic", pubsubTopic=pubsubTopic.get(),
        contentTopics=contentTopics
    else:
      error "failed legacy filter subscription", error=res.error
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])
  else:
    let topicMapRes = parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error=topicMapRes.error
        return
      else: topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "registering legacy filter subscription to content",
          pubsubTopic=pubsub,
          contentTopics=topics,
          peer=remotePeer.peerId

        let content = topics.mapIt($it)
        node.wakuFilterClientLegacy.subscribe($pubsub, content, handlerWrapper, peer=remotePeer)

    let finished = await allFinished(futures)

    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed legacy filter subscription", error=res.error
        waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

    for pubsub, topics in topicMap.pairs:
      info "subscribed to topic", pubsubTopic=pubsub, contentTopics=topics

proc filterSubscribe*(node: WakuNode,
                        pubsubTopic: Option[PubsubTopic],
                        contentTopics: ContentTopic|seq[ContentTopic],
                        peer: RemotePeerInfo|string):

                Future[FilterSubscribeResult]

                {.async, gcsafe, raises: [Defect, ValueError].} =

  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if node.wakuFilterClient.isNil():
    error "cannot register filter subscription to topic", error="waku filter client is not set up"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "Couldn't parse the peer info properly", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  if pubsubTopic.isSome():
    info "registering filter subscription to content", pubsubTopic=pubsubTopic.get(), contentTopics=contentTopics, peer=remotePeer.peerId

    let subRes = await node.wakuFilterClient.subscribe(remotePeer, pubsubTopic.get(), contentTopics)
    if subRes.isOk():
      info "v2 subscribed to topic", pubsubTopic=pubsubTopic, contentTopics=contentTopics
    else:
      error "failed filter v2 subscription", error=subRes.error
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

    return subRes
  else:
    let topicMapRes = parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error=topicMapRes.error
        return err(FilterSubscribeError.badResponse("can't get shard"))
      else: topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "registering filter subscription to content", pubsubTopic=pubsub, contentTopics=topics, peer=remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.subscribe(remotePeer, $pubsub, content)

    let finished = await allFinished(futures)

    var subRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed filter subscription", error=res.error
        waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])
        subRes = FilterSubscribeResult.err(res.error)

    for pubsub, topics in topicMap.pairs:
      info "subscribed to topic", pubsubTopic=pubsub, contentTopics=topics

    # return the last error or ok
    return subRes

proc legacyFilterUnsubscribe*(node: WakuNode,
                              pubsubTopic: Option[PubsubTopic],
                              contentTopics: ContentTopic|seq[ContentTopic],
                              peer: RemotePeerInfo|string)
                              {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Unsubscribe from a content legacy filter.
  if node.wakuFilterClientLegacy.isNil():
    error "cannot unregister filter subscription to content", error="waku filter client is nil"
    return

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "couldn't parse remotePeerInfo", error = remotePeerRes.error
    return

  let remotePeer = remotePeerRes.value

  if pubsubTopic.isSome():
    info "deregistering legacy filter subscription to content", pubsubTopic=pubsubTopic.get(), contentTopics=contentTopics, peer=remotePeer.peerId

    let res = await node.wakuFilterClientLegacy.unsubscribe(pubsubTopic.get(), contentTopics, peer=remotePeer)

    if res.isOk():
      info "unsubscribed from topic", pubsubTopic=pubsubTopic.get(), contentTopics=contentTopics
    else:
      error "failed filter unsubscription", error=res.error
      waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
  else:
    let topicMapRes = parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error = topicMapRes.error
        return
      else: topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "deregistering filter subscription to content", pubsubTopic=pubsub, contentTopics=topics, peer=remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClientLegacy.unsubscribe($pubsub, content, peer=remotePeer)

    let finished = await allFinished(futures)

    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed filter unsubscription", error=res.error
        waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

    for pubsub, topics in topicMap.pairs:
      info "unsubscribed from topic", pubsubTopic=pubsub, contentTopics=topics

proc filterUnsubscribe*(node: WakuNode,
                          pubsubTopic: Option[PubsubTopic],
                          contentTopics: seq[ContentTopic],
                          peer: RemotePeerInfo|string):

                Future[FilterSubscribeResult]

                {.async, gcsafe, raises: [Defect, ValueError].} =

  ## Unsubscribe from a content filter V2".
  if node.wakuFilterClientLegacy.isNil():
    error "cannot unregister filter subscription to content", error="waku filter client is nil"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "couldn't parse remotePeerInfo", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  if pubsubTopic.isSome():
    info "deregistering filter subscription to content", pubsubTopic=pubsubTopic.get(), contentTopics=contentTopics, peer=remotePeer.peerId

    let unsubRes = await node.wakuFilterClient.unsubscribe(remotePeer, pubsubTopic.get(), contentTopics)
    if unsubRes.isOk():
      info "unsubscribed from topic", pubsubTopic=pubsubTopic.get(), contentTopics=contentTopics
    else:
      error "failed filter unsubscription", error=unsubRes.error
      waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

    return unsubRes

  else: # pubsubTopic.isNone
    let topicMapRes = parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error = topicMapRes.error
        return err(FilterSubscribeError.badResponse("can't get shard"))
      else: topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "deregistering filter subscription to content", pubsubTopic=pubsub, contentTopics=topics, peer=remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.unsubscribe(remotePeer, $pubsub, content)

    let finished = await allFinished(futures)

    var unsubRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed filter unsubscription", error=res.error
        waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
        unsubRes = FilterSubscribeResult.err(res.error)

    for pubsub, topics in topicMap.pairs:
      info "unsubscribed from topic", pubsubTopic=pubsub, contentTopics=topics

    # return the last error or ok
    return unsubRes

proc filterUnsubscribeAll*(node: WakuNode,
                           peer: RemotePeerInfo|string):

                Future[FilterSubscribeResult]

                {.async, gcsafe, raises: [Defect, ValueError].} =

  ## Unsubscribe from a content filter V2".
  if node.wakuFilterClientLegacy.isNil():
    error "cannot unregister filter subscription to content", error="waku filter client is nil"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "couldn't parse remotePeerInfo", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  info "deregistering all filter subscription to content", peer=remotePeer.peerId

  let unsubRes = await node.wakuFilterClient.unsubscribeAll(remotePeer)
  if unsubRes.isOk():
    info "unsubscribed from all content-topic", peerId=remotePeer.peerId
  else:
    error "failed filter unsubscription from all content-topic", error=unsubRes.error
    waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

  return unsubRes

# NOTICE: subscribe / unsubscribe methods are removed - they were already depricated
# yet incompatible to handle both type of filters - use specific filter registration instead

## Waku archive
const WakuArchiveDefaultRetentionPolicyInterval* = 30.minutes
proc mountArchive*(node: WakuNode,
                   driver: ArchiveDriver,
                   retentionPolicy = none(RetentionPolicy)):
                   Result[void, string] =

  let wakuArchiveRes = WakuArchive.new(driver,
                                       retentionPolicy)
  if wakuArchiveRes.isErr():
    return err("error in mountArchive: " & wakuArchiveRes.error)

  node.wakuArchive = wakuArchiveRes.get()

  try:
    let reportMetricRes = waitFor node.wakuArchive.reportStoredMessagesMetric()
    if reportMetricRes.isErr():
      return err("error in mountArchive: " & reportMetricRes.error)
  except CatchableError:
    return err("exception in mountArchive: " & getCurrentExceptionMsg())

  if retentionPolicy.isSome():
    try:
      debug "executing message retention policy"
      let retPolRes = waitFor node.wakuArchive.executeMessageRetentionPolicy()
      if retPolRes.isErr():
        return err("error in mountArchive: " & retPolRes.error)
    except CatchableError:
      return err("exception in mountArch-ret-pol: " & getCurrentExceptionMsg())

    node.wakuArchive.startMessageRetentionPolicyPeriodicTask(
      WakuArchiveDefaultRetentionPolicyInterval)

  return ok()

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
  let queryHandler: HistoryQueryHandler = proc(request: HistoryQuery): Future[HistoryResult] {.async.} =
      let request = request.toArchiveQuery()
      let response = await node.wakuArchive.findMessages(request)
      return response.toHistoryResult()

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
      let publishedCount = await node.wakuRelay.publish(pubsubTopic, message.encode().buffer)

      if publishedCount == 0:
        ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
        debug("Lightpush request has not been published to any peers")

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

proc lightpushPublish*(node: WakuNode, pubsubTopic: Option[PubsubTopic], message: WakuMessage, peer: RemotePeerInfo): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  if node.wakuLightpushClient.isNil():
    return err("waku lightpush client is nil")

  if pubsubTopic.isSome():
    debug "publishing message with lightpush", pubsubTopic=pubsubTopic.get(), contentTopic=message.contentTopic, peer=peer.peerId
    return await node.wakuLightpushClient.publish(pubsubTopic.get(), message, peer)

  let topicMapRes = parseSharding(pubsubTopic, message.contentTopic)

  let topicMap =
    if topicMapRes.isErr():
      return err(topicMapRes.error)
    else: topicMapRes.get()

  for pubsub, _ in topicMap.pairs: # There's only one pair anyway
    debug "publishing message with lightpush", pubsubTopic=pubsub, contentTopic=message.contentTopic, peer=peer.peerId
    return await node.wakuLightpushClient.publish($pubsub, message, peer)

# TODO: Move to application module (e.g., wakunode2.nim)
proc lightpushPublish*(node: WakuNode, pubsubTopic: Option[PubsubTopic], message: WakuMessage): Future[void] {.async, gcsafe,
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
proc mountRlnRelay*(node: WakuNode,
                    rlnConf: WakuRlnConfig,
                    spamHandler = none(SpamHandler),
                    registrationHandler = none(RegistrationHandler)) {.async.} =
  info "mounting rln relay"

  if node.wakuRelay.isNil():
    raise newException(CatchableError, "WakuRelay protocol is not mounted, cannot mount WakuRlnRelay")

  let rlnRelayRes = waitFor WakuRlnRelay.new(rlnConf,
                                            registrationHandler)
  if rlnRelayRes.isErr():
    raise newException(CatchableError, "failed to mount WakuRlnRelay: " & rlnRelayRes.error)
  let rlnRelay = rlnRelayRes.get()
  let validator = generateRlnValidator(rlnRelay, spamHandler)

  # register rln validator for all subscribed relay pubsub topics
  for pubsubTopic in node.wakuRelay.subscribedTopics:
    debug "Registering RLN validator for topic", pubsubTopic=pubsubTopic
    node.wakuRelay.addValidator(pubsubTopic, validator)
  node.wakuRlnRelay = rlnRelay

## Waku peer-exchange

proc mountPeerExchange*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting waku peer exchange"

  node.wakuPeerExchange = WakuPeerExchange.new(node.peerManager)

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
    let peers = pxPeersRes.get().peerInfos
    for pi in peers:
      var record: enr.Record
      if enr.fromBytes(record, pi.enr):
        node.peerManager.addPeer(record.toRemotePeerInfo().get, PeerExcahnge)
        validPeers += 1
    info "Retrieved peer info via peer exchange protocol", validPeers = validPeers, totalPeers = peers.len
  else:
    warn "Failed to retrieve peer info via peer exchange protocol", error = pxPeersRes.error

# TODO: Move to application module (e.g., wakunode2.nim)
proc setPeerExchangePeer*(node: WakuNode, peer: RemotePeerInfo|string) =
  if node.wakuPeerExchange.isNil():
    error "could not set peer, waku peer-exchange is nil"
    return

  info "Set peer-exchange peer", peer=peer

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "could not parse peer info", error = remotePeerRes.error
    return

  node.peerManager.addPeer(remotePeerRes.value, WakuPeerExchangeCodec)
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

proc mountRendezvous*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting rendezvous discovery protocol"

  node.rendezvous = RendezVous.new(node.switch)

  if node.started:
    await node.rendezvous.start()

  node.switch.mount(node.rendezvous)

proc isBindIpWithZeroPort(inputMultiAdd: MultiAddress): bool =
  let inputStr = $inputMultiAdd
  if inputStr.contains("0.0.0.0/tcp/0") or inputStr.contains("127.0.0.1/tcp/0"):
    return true

  return false

proc printNodeNetworkInfo*(node: WakuNode): void =
  let peerInfo = node.switch.peerInfo
  var listenStr = ""

  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs

  for address in node.announcedAddresses:
    var fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]"
    listenStr &= fulladdr

  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr
  info "DNS: discoverable ENR ", enr = node.enr.toUri()

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.

  waku_version.set(1, labelValues=[git_version])
  info "Starting Waku node", version=git_version

  var zeroPortPresent = false
  for address in node.announcedAddresses:
    if isBindIpWithZeroPort(address):
      zeroPortPresent = true

  if not zeroPortPresent:
    printNodeNetworkInfo(node)
  else:
    info "Listening port is dynamically allocated, address and ENR generation postponed"

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

  node.wakuMetadata.start()

  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  if not node.wakuRelay.isNil():
    await node.wakuRelay.stop()

  await node.switch.stop()
  node.peerManager.stop()

  if not node.wakuRlnRelay.isNil():
    await node.wakuRlnRelay.stop()

  node.started = false

proc isReady*(node: WakuNode): Future[bool] {.async.} =
  if node.wakuRlnRelay == nil:
    return true
  return await node.wakuRlnRelay.isReady()
  ## TODO: add other protocol `isReady` checks
