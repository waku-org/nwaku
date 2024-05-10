when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[hashes, options, sugar, tables, strutils, sequtils, os],
  chronos,
  chronicles,
  metrics,
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
  libp2p/transports/transport,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport
import
  ../waku_core,
  ../waku_core/topics/sharding,
  ../waku_relay,
  ../waku_archive,
  ../waku_store_legacy/protocol as legacy_store,
  ../waku_store_legacy/client as legacy_store_client,
  ../waku_store_legacy/common as legacy_store_common,
  ../waku_store/protocol as store,
  ../waku_store/client as store_client,
  ../waku_store/common as store_common,
  ../waku_filter_v2,
  ../waku_filter_v2/client as filter_client,
  ../waku_filter_v2/subscriptions as filter_subscriptions,
  ../waku_metadata,
  ../waku_sync,
  ../waku_lightpush/client as lightpush_client,
  ../waku_lightpush/common,
  ../waku_lightpush/protocol,
  ../waku_lightpush/self_req_handler,
  ../waku_enr,
  ../waku_peer_exchange,
  ../waku_rln_relay,
  ./config,
  ./peer_manager,
  ../common/ratelimit

declarePublicCounter waku_node_messages, "number of messages received", ["type"]
declarePublicHistogram waku_histogram_message_size,
  "message size histogram in kB",
  buckets = [0.0, 5.0, 15.0, 50.0, 75.0, 100.0, 125.0, 150.0, 300.0, 700.0, 1000.0, Inf]

declarePublicGauge waku_version,
  "Waku version info (in git describe format)", ["version"]
declarePublicGauge waku_node_errors, "number of wakunode errors", ["type"]
declarePublicGauge waku_lightpush_peers, "number of lightpush peers"
declarePublicGauge waku_filter_peers, "number of filter peers"
declarePublicGauge waku_store_peers, "number of store peers"
declarePublicGauge waku_px_peers,
  "number of peers (in the node's peerManager) supporting the peer exchange protocol"

logScope:
  topics = "waku node"

# TODO: Move to application instance (e.g., `WakuNode2`)
# Git version in git describe format (defined compile time)
const git_version* {.strdefine.} = "n/a"

# Default clientId
const clientId* = "Nimbus Waku v2 node"

const WakuNodeVersionString* = "version / git commit hash: " & git_version

# key and crypto modules different
type
  # TODO: Move to application instance (e.g., `WakuNode2`)
  WakuInfo* = object # NOTE One for simplicity, can extend later as needed
    listenAddresses*: seq[string]
    enrUri*: string #multiaddrStrings*: seq[string]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object
    peerManager*: PeerManager
    switch*: Switch
    wakuRelay*: WakuRelay
    wakuArchive*: WakuArchive
    wakuLegacyStore*: legacy_store.WakuStore
    wakuLegacyStoreClient*: legacy_store_client.WakuStoreClient
    wakuStore*: store.WakuStore
    wakuStoreClient*: store_client.WakuStoreClient
    wakuFilter*: waku_filter_v2.WakuFilter
    wakuFilterClient*: filter_client.WakuFilterClient
    wakuRlnRelay*: WakuRLNRelay
    wakuLightPush*: WakuLightPush
    wakuLightpushClient*: WakuLightPushClient
    wakuPeerExchange*: WakuPeerExchange
    wakuMetadata*: WakuMetadata
    wakuSharding*: Sharding
    wakuSync*: WakuSync
    enr*: enr.Record
    libp2pPing*: Ping
    rng*: ref rand.HmacDrbgContext
    rendezvous*: RendezVous
    announcedAddresses*: seq[MultiAddress]
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
    minConfidence = 0.7,
  )

  proc statusAndConfidenceHandler(
      networkReachability: NetworkReachability, confidence: Opt[float]
  ): Future[void] {.gcsafe, async.} =
    if confidence.isSome():
      info "Peer reachability status",
        networkReachability = networkReachability, confidence = confidence.get()

  autonatService.statusAndConfidenceHandler(statusAndConfidenceHandler)

  return autonatService

proc new*(
    T: type WakuNode,
    netConfig: NetConfig,
    enr: enr.Record,
    switch: Switch,
    peerManager: PeerManager,
    # TODO: make this argument required after tests are updated
    rng: ref HmacDrbgContext = crypto.newRng(),
): T {.raises: [Defect, LPError, IOError, TLSStreamProtocolError].} =
  ## Creates a Waku Node instance.

  info "Initializing networking", addrs = $netConfig.announcedAddresses

  let queue = newAsyncEventQueue[SubscriptionEvent](0)

  let node = WakuNode(
    peerManager: peerManager,
    switch: switch,
    rng: rng,
    enr: enr,
    announcedAddresses: netConfig.announcedAddresses,
    topicSubscriptionQueue: queue,
  )

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

  var listenStr: seq[string]
  for address in node.announcedAddresses:
    var fulladdr = $address & "/p2p/" & $peerInfo.peerId
    listenStr &= fulladdr
  let enrUri = node.enr.toUri()
  let wakuInfo = WakuInfo(listenAddresses: listenStr, enrUri: enrUri)
  return wakuInfo

proc connectToNodes*(
    node: WakuNode, nodes: seq[RemotePeerInfo] | seq[string], source = "api"
) {.async.} =
  ## `source` indicates source of node addrs (static config, api call, discovery, etc)
  # NOTE Connects to the node without a give protocol, which automatically creates streams for relay
  await peer_manager.connectToNodes(node.peerManager, nodes, source = source)

## Waku Sync

proc mountWakuSync*(
    node: WakuNode,
    maxFrameSize: int = DefaultMaxFrameSize,
    syncInterval: timer.Duration = DefaultSyncInterval,
    relayJitter: Duration = DefaultGossipSubJitter,
    enablePruning: bool = true, # For testing purposes
): Result[void, string] =
  if not node.wakuSync.isNil():
    return err("Waku sync already mounted, skipping")

  var prune = none(PruneCallback)

  if enablePruning:
    prune = some(
      proc(
          pruneStart: Timestamp, pruneStop: Timestamp, cursor: Option[WakuMessageHash]
      ): Future[
          Result[(seq[(WakuMessageHash, Timestamp)], Option[WakuMessageHash]), string]
      ] {.async: (raises: []), closure.} =
        let archiveCursor =
          if cursor.isSome():
            some(ArchiveCursor(hash: cursor.get()))
          else:
            none(ArchiveCursor)

        let query = ArchiveQuery(
          cursor: archiveCursor,
          startTime: some(pruneStart),
          endTime: some(pruneStop),
          pageSize: 100,
        )

        let catchable = catch:
          await node.wakuArchive.findMessages(query)

        let res =
          if catchable.isErr():
            return err(catchable.error.msg)
          else:
            catchable.get()

        let response = res.valueOr:
          return err($error)

        let elements = collect(newSeq):
          for (hash, msg) in response.hashes.zip(response.messages):
            (hash, msg.timestamp)

        let cursor =
          if response.cursor.isNone():
            none(WakuMessageHash)
          else:
            some(response.cursor.get().hash)

        return ok((elements, cursor))
    )

  let transfer: TransferCallback = proc(
      hashes: seq[WakuMessageHash], peerId: PeerId
  ): Future[Result[void, string]] {.async: (raises: []), closure.} =
    var query = StoreQueryRequest()
    query.includeData = true
    query.messageHashes = hashes
    query.paginationLimit = some(uint64(100))

    while true:
      # Do we need a query retry mechanism??
      let queryRes = catch:
        await node.wakuStoreClient.query(query, peerId)

      let res =
        if queryRes.isErr():
          return err(queryRes.error.msg)
        else:
          queryRes.get()

      let response = res.valueOr:
        return err($error)

      query.paginationCursor = response.paginationCursor

      for kv in response.messages:
        let handleRes = catch:
          await node.wakuArchive.handleMessage(kv.pubsubTopic.get(), kv.message.get())

        if handleRes.isErr():
          trace "message transfer failed", error = handleRes.error.msg
          # Messages can be synced next time since they are not added to storage yet.
          continue

        node.wakuSync.ingessMessage(kv.pubsubTopic.get(), kv.message.get())

      if query.paginationCursor.isNone():
        break

    return ok()

  node.wakuSync = WakuSync.new(
    peerManager = node.peerManager,
    maxFrameSize = maxFrameSize,
    syncInterval = syncInterval,
    relayJitter = relayJitter,
    pruneCB = prune,
    transferCB = some(transfer),
  )

  let catchRes = catch:
    node.switch.mount(node.wakuSync, protocolMatcher(WakuSyncCodec))
  if catchRes.isErr():
    return err(catchRes.error.msg)

  if node.started:
    node.wakuSync.start()

  return ok()

## Waku Metadata

proc mountMetadata*(node: WakuNode, clusterId: uint32): Result[void, string] =
  if not node.wakuMetadata.isNil():
    return err("Waku metadata already mounted, skipping")

  let metadata = WakuMetadata.new(clusterId, node.enr, node.topicSubscriptionQueue)

  node.wakuMetadata = metadata
  node.peerManager.wakuMetadata = metadata

  let catchRes = catch:
    node.switch.mount(node.wakuMetadata, protocolMatcher(WakuMetadataCodec))
  if catchRes.isErr():
    return err(catchRes.error.msg)

  return ok()

## Waku Sharding
proc mountSharding*(
    node: WakuNode, clusterId: uint32, shardCount: uint32
): Result[void, string] =
  info "mounting sharding", clusterId = clusterId, shardCount = shardCount
  node.wakuSharding = Sharding(clusterId: clusterId, shardCountGenZero: shardCount)
  return ok()

## Waku relay

proc registerRelayDefaultHandler(node: WakuNode, topic: PubsubTopic) =
  if node.wakuRelay.isSubscribed(topic):
    return

  proc traceHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    debug "waku.relay received",
      my_peer_id = node.peerId,
      pubsubTopic = topic,
      msg_hash = topic.computeMessageHash(msg).to0xHex(),
      receivedTime = getNowInNanosecondTime(),
      payloadSizeBytes = msg.payload.len

    let msgSizeKB = msg.payload.len / 1000

    waku_node_messages.inc(labelValues = ["relay"])
    waku_histogram_message_size.observe(msgSizeKB)

  proc filterHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuFilter.isNil():
      return

    await node.wakuFilter.handleMessage(topic, msg)

  proc archiveHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
    if node.wakuArchive.isNil():
      return

    await node.wakuArchive.handleMessage(topic, msg)

  proc syncHandler(topic: PubsubTopic, msg: WakuMessage) =
    if node.wakuSync.isNil():
      return

    node.wakuSync.ingessMessage(topic, msg)

  let defaultHandler = proc(
      topic: PubsubTopic, msg: WakuMessage
  ): Future[void] {.async, gcsafe.} =
    await traceHandler(topic, msg)
    await filterHandler(topic, msg)
    await archiveHandler(topic, msg)
    syncHandler(topic, msg)

  discard node.wakuRelay.subscribe(topic, defaultHandler)

proc subscribe*(
    node: WakuNode, subscription: SubscriptionEvent, handler = none(WakuRelayHandler)
) =
  ## Subscribes to a PubSub or Content topic. Triggers handler when receiving messages on
  ## this topic. WakuRelayHandler is a method that takes a topic and a Waku message.

  if node.wakuRelay.isNil():
    error "Invalid API call to `subscribe`. WakuRelay not mounted."
    return

  let (pubsubTopic, contentTopicOp) =
    case subscription.kind
    of ContentSub:
      let shard = node.wakuSharding.getShard((subscription.topic)).valueOr:
        error "Autosharding error", error = error
        return

      (shard, some(subscription.topic))
    of PubsubSub:
      (subscription.topic, none(ContentTopic))
    else:
      return

  if contentTopicOp.isSome() and node.contentTopicHandlers.hasKey(contentTopicOp.get()):
    error "Invalid API call to `subscribe`. Was already subscribed"
    return

  debug "subscribe", pubsubTopic = pubsubTopic

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
    case subscription.kind
    of ContentUnsub:
      let shard = node.wakuSharding.getShard((subscription.topic)).valueOr:
        error "Autosharding error", error = error
        return

      (shard, some(subscription.topic))
    of PubsubUnsub:
      (subscription.topic, none(ContentTopic))
    else:
      return

  if not node.wakuRelay.isSubscribed(pubsubTopic):
    error "Invalid API call to `unsubscribe`. Was not subscribed"
    return

  if contentTopicOp.isSome():
    # Remove this handler only
    var handler: TopicHandler
    if node.contentTopicHandlers.pop(contentTopicOp.get(), handler):
      debug "unsubscribe", contentTopic = contentTopicOp.get()
      node.wakuRelay.unsubscribe(pubsubTopic, handler)

  if contentTopicOp.isNone() or node.wakuRelay.topics.getOrDefault(pubsubTopic).len == 1:
    # Remove all handlers
    debug "unsubscribe", pubsubTopic = pubsubTopic
    node.wakuRelay.unsubscribeAll(pubsubTopic)
    node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: pubsubTopic))

proc publish*(
    node: WakuNode, pubsubTopicOp: Option[PubsubTopic], message: WakuMessage
): Future[Result[void, string]] {.async, gcsafe.} =
  ## Publish a `WakuMessage`. Pubsub topic contains; none, a named or static shard.
  ## `WakuMessage` should contain a `contentTopic` field for light node functionality.
  ## It is also used to determine the shard.

  if node.wakuRelay.isNil():
    let msg =
      "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    error "publish error", msg = msg
    # TODO: Improve error handling
    return err(msg)

  let pubsubTopic = pubsubTopicOp.valueOr:
    node.wakuSharding.getShard(message.contentTopic).valueOr:
      let msg = "Autosharding error: " & error
      error "publish error", msg = msg
      return err(msg)

  #TODO instead of discard return error when 0 peers received the message
  discard await node.wakuRelay.publish(pubsubTopic, message)

  trace "waku.relay published",
    peerId = node.peerId,
    pubsubTopic = pubsubTopic,
    hash = pubsubTopic.computeMessageHash(message).to0xHex(),
    publishTime = getNowInNanosecondTime()

  return ok()

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
    let backoffPeriod =
      node.wakuRelay.parameters.pruneBackoff + chronos.seconds(BackoffSlackTime)

    await node.peerManager.reconnectPeers(WakuRelayCodec, backoffPeriod)

  # Start the WakuRelay protocol
  await node.wakuRelay.start()

  info "relay started successfully"

proc mountRelay*(
    node: WakuNode,
    pubsubTopics: seq[string] = @[],
    peerExchangeHandler = none(RoutingRecordsHandler),
    maxMessageSize = int(DefaultMaxWakuMessageSize),
) {.async, gcsafe.} =
  if not node.wakuRelay.isNil():
    error "wakuRelay already mounted, skipping"
    return

  ## The default relay topics is the union of all configured topics plus default PubsubTopic(s)
  info "mounting relay protocol"

  let initRes = WakuRelay.new(node.switch, maxMessageSize)
  if initRes.isErr():
    error "failed mounting relay protocol", error = initRes.error
    return

  node.wakuRelay = initRes.value

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    node.wakuRelay.parameters.enablePX = true
      # Feature flag for peer exchange in nim-libp2p
    node.wakuRelay.routingRecordsHandler.add(peerExchangeHandler.get())

  if node.started:
    await node.startRelay()

  node.switch.mount(node.wakuRelay, protocolMatcher(WakuRelayCodec))

  info "relay mounted successfully"

  # Subscribe to topics
  for pubsubTopic in pubsubTopics:
    node.subscribe((kind: PubsubSub, topic: pubsubTopic))

## Waku filter

proc mountFilter*(
    node: WakuNode,
    subscriptionTimeout: Duration =
      filter_subscriptions.DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = filter_subscriptions.MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = filter_subscriptions.MaxFilterCriteriaPerPeer,
) {.async, raises: [Defect, LPError].} =
  ## Mounting filter v2 protocol

  info "mounting filter protocol"
  node.wakuFilter = WakuFilter.new(
    node.peerManager, subscriptionTimeout, maxFilterPeers, maxFilterCriteriaPerPeer
  )

  if node.started:
    await node.wakuFilter.start()

  node.switch.mount(node.wakuFilter, protocolMatcher(WakuFilterSubscribeCodec))

proc filterHandleMessage*(
    node: WakuNode, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async.} =
  if node.wakuFilter.isNil():
    error "cannot handle filter message", error = "waku filter is required"
    return

  await node.wakuFilter.handleMessage(pubsubTopic, message)

proc mountFilterClient*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  ## Mounting both filter
  ## Giving option for application level to choose btw own push message handling or
  ## rely on node provided cache. - This only applies for v2 filter client
  info "mounting filter client"

  node.wakuFilterClient = WakuFilterClient.new(node.peerManager, node.rng)

  if node.started:
    await node.wakuFilterClient.start()

  node.switch.mount(node.wakuFilterClient, protocolMatcher(WakuFilterSubscribeCodec))

proc filterSubscribe*(
    node: WakuNode,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if node.wakuFilterClient.isNil():
    error "cannot register filter subscription to topic",
      error = "waku filter client is not set up"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "Couldn't parse the peer info properly", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  if pubsubTopic.isSome():
    info "registering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    when (contentTopics is ContentTopic):
      let contentTopics = @[contentTopics]
    let subRes = await node.wakuFilterClient.subscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if subRes.isOk():
      info "v2 subscribed to topic",
        pubsubTopic = pubsubTopic, contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: pubsubTopic.get()))
    else:
      error "failed filter v2 subscription", error = subRes.error
      waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])

    return subRes
  else:
    let topicMapRes = node.wakuSharding.parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error = topicMapRes.error
        return err(FilterSubscribeError.badResponse("can't get shard"))
      else:
        topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "registering filter subscription to content",
          pubsubTopic = pubsub, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.subscribe(remotePeer, $pubsub, content)

    let finished = await allFinished(futures)

    var subRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed filter subscription", error = res.error
        waku_node_errors.inc(labelValues = ["subscribe_filter_failure"])
        subRes = FilterSubscribeResult.err(res.error)

    for pubsub, topics in topicMap.pairs:
      info "subscribed to topic", pubsubTopic = pubsub, contentTopics = topics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubSub, topic: $pubsub))

    # return the last error or ok
    return subRes

proc filterUnsubscribe*(
    node: WakuNode,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Unsubscribe from a content filter V2".

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "couldn't parse remotePeerInfo", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  if pubsubTopic.isSome():
    info "deregistering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    let unsubRes = await node.wakuFilterClient.unsubscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if unsubRes.isOk():
      info "unsubscribed from topic",
        pubsubTopic = pubsubTopic.get(), contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: pubsubTopic.get()))
    else:
      error "failed filter unsubscription", error = unsubRes.error
      waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

    return unsubRes
  else: # pubsubTopic.isNone
    let topicMapRes = node.wakuSharding.parseSharding(pubsubTopic, contentTopics)

    let topicMap =
      if topicMapRes.isErr():
        error "can't get shard", error = topicMapRes.error
        return err(FilterSubscribeError.badResponse("can't get shard"))
      else:
        topicMapRes.get()

    var futures = collect(newSeq):
      for pubsub, topics in topicMap.pairs:
        info "deregistering filter subscription to content",
          pubsubTopic = pubsub, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        node.wakuFilterClient.unsubscribe(remotePeer, $pubsub, content)

    let finished = await allFinished(futures)

    var unsubRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    for fut in finished:
      let res = fut.read()

      if res.isErr():
        error "failed filter unsubscription", error = res.error
        waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
        unsubRes = FilterSubscribeResult.err(res.error)

    for pubsub, topics in topicMap.pairs:
      info "unsubscribed from topic", pubsubTopic = pubsub, contentTopics = topics

      # Purpose is to update Waku Metadata
      node.topicSubscriptionQueue.emit((kind: PubsubUnsub, topic: $pubsub))

    # return the last error or ok
    return unsubRes

proc filterUnsubscribeAll*(
    node: WakuNode, peer: RemotePeerInfo | string
): Future[FilterSubscribeResult] {.async, gcsafe, raises: [Defect, ValueError].} =
  ## Unsubscribe from a content filter V2".

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "couldn't parse remotePeerInfo", error = remotePeerRes.error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  let remotePeer = remotePeerRes.value

  info "deregistering all filter subscription to content", peer = remotePeer.peerId

  let unsubRes = await node.wakuFilterClient.unsubscribeAll(remotePeer)
  if unsubRes.isOk():
    info "unsubscribed from all content-topic", peerId = remotePeer.peerId
  else:
    error "failed filter unsubscription from all content-topic", error = unsubRes.error
    waku_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

  return unsubRes

# NOTICE: subscribe / unsubscribe methods are removed - they were already depricated
# yet incompatible to handle both type of filters - use specific filter registration instead

## Waku archive
proc mountArchive*(
    node: WakuNode, driver: ArchiveDriver, retentionPolicy = none(RetentionPolicy)
): Result[void, string] =
  node.wakuArchive = WakuArchive.new(driver = driver, retentionPolicy = retentionPolicy).valueOr:
    return err("error in mountArchive: " & error)

  node.wakuArchive.start()

  return ok()

## Legacy Waku Store

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toArchiveQuery(request: legacy_store_common.HistoryQuery): ArchiveQuery =
  ArchiveQuery(
    pubsubTopic: request.pubsubTopic,
    contentTopics: request.contentTopics,
    cursor: request.cursor.map(
      proc(cursor: HistoryCursor): ArchiveCursor =
        ArchiveCursor(
          pubsubTopic: cursor.pubsubTopic,
          senderTime: cursor.senderTime,
          storeTime: cursor.storeTime,
          digest: cursor.digest,
        )
    ),
    startTime: request.startTime,
    endTime: request.endTime,
    pageSize: request.pageSize.uint,
    direction: request.direction,
  )

# TODO: Review this mapping logic. Maybe, move it to the appplication code
proc toHistoryResult*(res: ArchiveResult): legacy_store_common.HistoryResult =
  if res.isErr():
    let error = res.error
    case res.error.kind
    of ArchiveErrorKind.DRIVER_ERROR, ArchiveErrorKind.INVALID_QUERY:
      err(HistoryError(kind: HistoryErrorKind.BAD_REQUEST, cause: res.error.cause))
    else:
      err(HistoryError(kind: HistoryErrorKind.UNKNOWN))
  else:
    let response = res.get()
    ok(
      HistoryResponse(
        messages: response.messages,
        cursor: response.cursor.map(
          proc(cursor: ArchiveCursor): HistoryCursor =
            HistoryCursor(
              pubsubTopic: cursor.pubsubTopic,
              senderTime: cursor.senderTime,
              storeTime: cursor.storeTime,
              digest: cursor.digest,
            )
        ),
      )
    )

proc mountLegacyStore*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  info "mounting waku legacy store protocol"

  if node.wakuArchive.isNil():
    error "failed to mount waku legacy store protocol", error = "waku archive not set"
    return

  # TODO: Review this handler logic. Maybe, move it to the appplication code
  let queryHandler: HistoryQueryHandler = proc(
      request: HistoryQuery
  ): Future[legacy_store_common.HistoryResult] {.async.} =
    if request.cursor.isSome():
      request.cursor.get().checkHistCursor().isOkOr:
        return err(error)

    let request = request.toArchiveQuery()
    let response = await node.wakuArchive.findMessagesV2(request)
    return response.toHistoryResult()

  node.wakuLegacyStore = legacy_store.WakuStore.new(
    node.peerManager, node.rng, queryHandler, some(rateLimit)
  )

  if node.started:
    # Node has started already. Let's start store too.
    await node.wakuLegacyStore.start()

  node.switch.mount(
    node.wakuLegacyStore, protocolMatcher(legacy_store_common.WakuStoreCodec)
  )

proc mountLegacyStoreClient*(node: WakuNode) =
  info "mounting legacy store client"

  node.wakuLegacyStoreClient =
    legacy_store_client.WakuStoreClient.new(node.peerManager, node.rng)

proc query*(
    node: WakuNode, query: legacy_store_common.HistoryQuery, peer: RemotePeerInfo
): Future[legacy_store_common.WakuStoreResult[legacy_store_common.HistoryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if node.wakuLegacyStoreClient.isNil():
    return err("waku legacy store client is nil")

  let queryRes = await node.wakuLegacyStoreClient.query(query, peer)
  if queryRes.isErr():
    return err("legacy store client query error: " & $queryRes.error)

  let response = queryRes.get()

  return ok(response)

# TODO: Move to application module (e.g., wakunode2.nim)
proc query*(
    node: WakuNode, query: legacy_store_common.HistoryQuery
): Future[legacy_store_common.WakuStoreResult[legacy_store_common.HistoryResponse]] {.
    async, gcsafe, deprecated: "Use 'node.query()' with peer destination instead"
.} =
  ## Queries known nodes for historical messages
  if node.wakuLegacyStoreClient.isNil():
    return err("waku legacy store client is nil")

  let peerOpt = node.peerManager.selectPeer(legacy_store_common.WakuStoreCodec)
  if peerOpt.isNone():
    error "no suitable remote peers"
    return err("peer_not_found_failure")

  return await node.query(query, peerOpt.get())

when defined(waku_exp_store_resume):
  # TODO: Move to application module (e.g., wakunode2.nim)
  proc resume*(
      node: WakuNode, peerList: Option[seq[RemotePeerInfo]] = none(seq[RemotePeerInfo])
  ) {.async, gcsafe.} =
    ## resume proc retrieves the history of waku messages published on the default waku pubsub topic since the last time the waku node has been online
    ## for resume to work properly the waku node must have the store protocol mounted in the full mode (i.e., persisting messages)
    ## messages are stored in the wakuStore's messages field and in the message db
    ## the offline time window is measured as the difference between the current time and the timestamp of the most recent persisted waku message
    ## an offset of 20 second is added to the time window to count for nodes asynchrony
    ## peerList indicates the list of peers to query from. The history is fetched from the first available peer in this list. Such candidates should be found through a discovery method (to be developed).
    ## if no peerList is passed, one of the peers in the underlying peer manager unit of the store protocol is picked randomly to fetch the history from.
    ## The history gets fetched successfully if the dialed peer has been online during the queried time window.
    if node.wakuLegacyStoreClient.isNil():
      return

    let retrievedMessages = await node.wakuLegacyStoreClient.resume(peerList)
    if retrievedMessages.isErr():
      error "failed to resume store", error = retrievedMessages.error
      return

    info "the number of retrieved messages since the last online time: ",
      number = retrievedMessages.value

## Waku Store

proc toArchiveQuery(request: StoreQueryRequest): ArchiveQuery =
  var query = ArchiveQuery()

  query.includeData = request.includeData
  query.pubsubTopic = request.pubsubTopic
  query.contentTopics = request.contentTopics
  query.startTime = request.startTime
  query.endTime = request.endTime
  query.hashes = request.messageHashes

  if request.paginationCursor.isSome():
    var cursor = ArchiveCursor()
    cursor.hash = request.paginationCursor.get()
    query.cursor = some(cursor)

  query.direction = request.paginationForward

  if request.paginationLimit.isSome():
    query.pageSize = uint(request.paginationLimit.get())

  return query

proc toStoreResult(res: ArchiveResult): StoreQueryResult =
  let response = res.valueOr:
    return err(StoreError.new(300, "archive error: " & $error))

  var res = StoreQueryResponse()

  res.statusCode = 200
  res.statusDesc = "OK"

  for i in 0 ..< response.hashes.len:
    let hash = response.hashes[i]

    let kv = store_common.WakuMessageKeyValue(messageHash: hash)

    res.messages.add(kv)

  for i in 0 ..< response.messages.len:
    res.messages[i].message = some(response.messages[i])
    res.messages[i].pubsubTopic = some(response.topics[i])

  if response.cursor.isSome():
    res.paginationCursor = some(response.cursor.get().hash)

  return ok(res)

proc mountStore*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  if node.wakuArchive.isNil():
    error "failed to mount waku store protocol", error = "waku archive not set"
    return

  info "mounting waku store protocol"

  let requestHandler: StoreQueryRequestHandler = proc(
      request: StoreQueryRequest
  ): Future[StoreQueryResult] {.async.} =
    let request = request.toArchiveQuery()
    let response = await node.wakuArchive.findMessages(request)

    return response.toStoreResult()

  node.wakuStore =
    store.WakuStore.new(node.peerManager, node.rng, requestHandler, some(rateLimit))

  if node.started:
    await node.wakuStore.start()

  node.switch.mount(node.wakuStore, protocolMatcher(store_common.WakuStoreCodec))

proc mountStoreClient*(node: WakuNode) =
  info "mounting store client"

  node.wakuStoreClient = store_client.WakuStoreClient.new(node.peerManager, node.rng)

proc query*(
    node: WakuNode, request: store_common.StoreQueryRequest, peer: RemotePeerInfo
): Future[store_common.WakuStoreResult[store_common.StoreQueryResponse]] {.
    async, gcsafe
.} =
  ## Queries known nodes for historical messages
  if node.wakuStoreClient.isNil():
    return err("waku store v3 client is nil")

  let response = (await node.wakuStoreClient.query(request, peer)).valueOr:
    var res = StoreQueryResponse()
    res.statusCode = uint32(error.kind)
    res.statusDesc = $error

    return ok(res)

  return ok(response)

## Waku lightpush

proc mountLightPush*(
    node: WakuNode, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
) {.async.} =
  info "mounting light push"

  var pushHandler: PushMessageHandler
  if node.wakuRelay.isNil():
    debug "mounting lightpush without relay (nil)"
    pushHandler = proc(
        peer: PeerId, pubsubTopic: string, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      return err("no waku relay found")
  else:
    pushHandler = proc(
        peer: PeerId, pubsubTopic: string, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      let publishedCount =
        await node.wakuRelay.publish(pubsubTopic, message.encode().buffer)

      if publishedCount == 0:
        ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
        let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
        debug "Lightpush request has not been published to any peers",
          msg_hash = msgHash

      return ok()

  debug "mounting lightpush with relay"
  node.wakuLightPush =
    WakuLightPush.new(node.peerManager, node.rng, pushHandler, some(rateLimit))

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.wakuLightPush.start()

  node.switch.mount(node.wakuLightPush, protocolMatcher(WakuLightPushCodec))

proc mountLightPushClient*(node: WakuNode) =
  info "mounting light push client"

  node.wakuLightpushClient = WakuLightPushClient.new(node.peerManager, node.rng)

proc lightpushPublish*(
    node: WakuNode,
    pubsubTopic: Option[PubsubTopic],
    message: WakuMessage,
    peer: RemotePeerInfo,
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  if node.wakuLightpushClient.isNil() and node.wakuLightPush.isNil():
    error "failed to publish message as lightpush not available"
    return err("Waku lightpush not available")

  let internalPublish = proc(
      node: WakuNode,
      pubsubTopic: PubsubTopic,
      message: WakuMessage,
      peer: RemotePeerInfo,
  ): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
    let msgHash = pubsubTopic.computeMessageHash(message).to0xHex()
    if not node.wakuLightpushClient.isNil():
      debug "publishing message with lightpush",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        target_peer_id = peer.peerId,
        msg_hash = msgHash
      return await node.wakuLightpushClient.publish(pubsubTopic, message, peer)

    if not node.wakuLightPush.isNil():
      debug "publishing message with self hosted lightpush",
        pubsubTopic = pubsubTopic,
        contentTopic = message.contentTopic,
        target_peer_id = peer.peerId,
        msg_hash = msgHash
      return await node.wakuLightPush.handleSelfLightPushRequest(pubsubTopic, message)

  if pubsubTopic.isSome():
    return await internalPublish(node, pubsubTopic.get(), message, peer)

  let topicMapRes = node.wakuSharding.parseSharding(pubsubTopic, message.contentTopic)

  let topicMap =
    if topicMapRes.isErr():
      return err(topicMapRes.error)
    else:
      topicMapRes.get()

  for pubsub, _ in topicMap.pairs: # There's only one pair anyway
    return await internalPublish(node, $pubsub, message, peer)

# TODO: Move to application module (e.g., wakunode2.nim)
proc lightpushPublish*(
    node: WakuNode, pubsubTopic: Option[PubsubTopic], message: WakuMessage
): Future[WakuLightPushResult[void]] {.
    async, gcsafe, deprecated: "Use 'node.lightpushPublish()' instead"
.} =
  if node.wakuLightpushClient.isNil() and node.wakuLightPush.isNil():
    error "failed to publish message as lightpush not available"
    return err("waku lightpush not available")

  var peerOpt: Option[RemotePeerInfo] = none(RemotePeerInfo)
  if not node.wakuLightpushClient.isNil():
    peerOpt = node.peerManager.selectPeer(WakuLightPushCodec)
    if peerOpt.isNone():
      let msg = "no suitable remote peers"
      error "failed to publish message", msg = msg
      return err(msg)
  elif not node.wakuLightPush.isNil():
    peerOpt = some(RemotePeerInfo.init($node.switch.peerInfo.peerId))

  let publishRes =
    await node.lightpushPublish(pubsubTopic, message, peer = peerOpt.get())

  if publishRes.isErr():
    error "failed to publish message", error = publishRes.error

  return publishRes

## Waku RLN Relay
proc mountRlnRelay*(
    node: WakuNode,
    rlnConf: WakuRlnConfig,
    spamHandler = none(SpamHandler),
    registrationHandler = none(RegistrationHandler),
) {.async.} =
  info "mounting rln relay"

  if node.wakuRelay.isNil():
    raise newException(
      CatchableError, "WakuRelay protocol is not mounted, cannot mount WakuRlnRelay"
    )

  let rlnRelayRes = waitFor WakuRlnRelay.new(rlnConf, registrationHandler)
  if rlnRelayRes.isErr():
    raise
      newException(CatchableError, "failed to mount WakuRlnRelay: " & rlnRelayRes.error)
  let rlnRelay = rlnRelayRes.get()
  let validator = generateRlnValidator(rlnRelay, spamHandler)

  # register rln validator as default validator
  debug "Registering RLN validator"
  node.wakuRelay.addValidator(validator, "RLN validation failed")

  node.wakuRlnRelay = rlnRelay

## Waku peer-exchange

proc mountPeerExchange*(node: WakuNode) {.async, raises: [Defect, LPError].} =
  info "mounting waku peer exchange"

  node.wakuPeerExchange = WakuPeerExchange.new(node.peerManager)

  if node.started:
    await node.wakuPeerExchange.start()

  node.switch.mount(node.wakuPeerExchange, protocolMatcher(WakuPeerExchangeCodec))

proc fetchPeerExchangePeers*(
    node: Wakunode, amount: uint64
): Future[Result[int, string]] {.async: (raises: []).} =
  if node.wakuPeerExchange.isNil():
    error "could not get peers from px, waku peer-exchange is nil"
    return err("PeerExchange is not mounted")

  info "Retrieving peer info via peer exchange protocol"
  let pxPeersRes = await node.wakuPeerExchange.request(amount)
  if pxPeersRes.isOk:
    var validPeers = 0
    let peers = pxPeersRes.get().peerInfos
    for pi in peers:
      var record: enr.Record
      if enr.fromBytes(record, pi.enr):
        node.peerManager.addPeer(record.toRemotePeerInfo().get, PeerExchange)
        validPeers += 1
    info "Retrieved peer info via peer exchange protocol",
      validPeers = validPeers, totalPeers = peers.len
    return ok(validPeers)
  else:
    warn "failed to retrieve peer info via peer exchange protocol",
      error = pxPeersRes.error
    return err("Peer exchange failure: " & $pxPeersRes.error)

# TODO: Move to application module (e.g., wakunode2.nim)
proc setPeerExchangePeer*(
    node: WakuNode, peer: RemotePeerInfo | MultiAddress | string
) =
  if node.wakuPeerExchange.isNil():
    error "could not set peer, waku peer-exchange is nil"
    return

  info "Set peer-exchange peer", peer = peer

  let remotePeerRes = parsePeerInfo(peer)
  if remotePeerRes.isErr():
    error "could not parse peer info", error = remotePeerRes.error
    return

  node.peerManager.addPeer(remotePeerRes.value, PeerExchange)
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
    let peers =
      node.peerManager.peerStore.peers().filterIt(it.connectedness == Connected)

    for peer in peers:
      try:
        let conn = await node.switch.dial(peer.peerId, peer.addrs, PingCodec)
        let pingDelay = await node.libp2pPing.ping(conn)
      except CatchableError as exc:
        waku_node_errors.inc(labelValues = ["keep_alive_failure"])

    await sleepAsync(keepalive)

proc startKeepalive*(node: WakuNode) =
  let defaultKeepalive = 2.minutes # 20% of the default chronosstream timeout duration

  info "starting keepalive", keepalive = defaultKeepalive

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
  var announcedStr = ""
  var listenStr = ""
  var localIp = ""

  try:
    localIp = $getPrimaryIPAddr()
  except Exception as e:
    warn "Could not retrieve localIp", msg = e.msg

  info "PeerInfo", peerId = peerInfo.peerId, addrs = peerInfo.addrs

  for address in node.announcedAddresses:
    var fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]"
    announcedStr &= fulladdr

  for transport in node.switch.transports:
    for address in transport.addrs:
      var fulladdr = "[" & $address & "/p2p/" & $peerInfo.peerId & "]"
      listenStr &= fulladdr

  ## XXX: this should be /ip4..., / stripped?
  info "Listening on", full = listenStr, localIp = localIp
  info "Announcing addresses", full = announcedStr
  info "DNS: discoverable ENR ", enr = node.enr.toUri()

proc start*(node: WakuNode) {.async.} =
  ## Starts a created Waku Node and
  ## all its mounted protocols.

  waku_version.set(1, labelValues = [git_version])
  info "Starting Waku node", version = git_version

  var zeroPortPresent = false
  for address in node.announcedAddresses:
    if isBindIpWithZeroPort(address):
      zeroPortPresent = true

  # Perform relay-specific startup tasks TODO: this should be rethought
  if not node.wakuRelay.isNil():
    await node.startRelay()

  if not node.wakuMetadata.isNil():
    node.wakuMetadata.start()

  if not node.wakuSync.isNil():
    node.wakuSync.start()

  ## The switch uses this mapper to update peer info addrs
  ## with announced addrs after start
  let addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async.} =
    return node.announcedAddresses
  node.switch.peerInfo.addressMappers.add(addressMapper)

  ## The switch will update addresses after start using the addressMapper
  await node.switch.start()

  node.started = true

  if not zeroPortPresent:
    printNodeNetworkInfo(node)
  else:
    info "Listening port is dynamically allocated, address and ENR generation postponed"

  info "Node started successfully"

proc stop*(node: WakuNode) {.async.} =
  ## By stopping the switch we are stopping all the underlying mounted protocols
  await node.switch.stop()

  node.peerManager.stop()

  if not node.wakuRlnRelay.isNil():
    try:
      await node.wakuRlnRelay.stop() ## this can raise an exception
    except Exception:
      error "exception stopping the node", error = getCurrentExceptionMsg()

  if not node.wakuArchive.isNil():
    await node.wakuArchive.stopWait()

  node.started = false

proc isReady*(node: WakuNode): Future[bool] {.async: (raises: [Exception]).} =
  if node.wakuRlnRelay == nil:
    return true
  return await node.wakuRlnRelay.isReady()
  ## TODO: add other protocol `isReady` checks
