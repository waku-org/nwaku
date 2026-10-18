## Waku layer API — filter (light client) operations.
{.push raises: [].}

import
  std/[sugar, tables, sequtils, os, net],
  chronos,
  chronicles,
  metrics,
  results,
  stew/byteutils,
  eth/keys,
  nimcrypto,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport

import
  logos_delivery/kernel/[
    kernel,
    metrics_server,
    protocols/topics/content_topic,
    protocols/topics/pubsub_topic,
    common/enr/sharding,
    protocols/message,
    peer_manager/peers,
    protocols/codecs,
    protocols/filter/common,
    protocols/filter/protocol,
    protocols/filter/subscriptions,
    protocols/filter/client as filter_client,
    protocols/filter/subscriptions as filter_subscriptions,
    common/rate_limit/setting,
    events/subscription_events,
    peer_manager/peer_manager,
  ]
logScope:
  topics = "waku node filter api"

## Waku filter

import results, chronos, chronicles

import
  logos_delivery/kernel/[
    protocols/topics/content_topic,
    protocols/topics/pubsub_topic,
    common/enr/sharding,
    peer_manager/peers,
    protocols/codecs,
    peer_manager/peer_manager,
    protocols/filter/client,
    protocols/filter/common,
  ]

proc mountFilter*(
    self: Kernel,
    subscriptionTimeout: Duration =
      filter_subscriptions.DefaultSubscriptionTimeToLiveSec,
    maxFilterPeers: uint32 = filter_subscriptions.MaxFilterPeers,
    maxFilterCriteriaPerPeer: uint32 = filter_subscriptions.MaxFilterCriteriaPerPeer,
    messageCacheTTL: Duration = filter_subscriptions.MessageCacheTTL,
    rateLimitSetting: RateLimitSetting = FilterDefaultPerPeerRateLimit,
) {.async: (raises: []).} =
  ## Mounting filter v2 protocol

  info "mounting filter protocol"
  self.protocols.filter = WakuFilter.new(
    self.peerManager,
    subscriptionTimeout,
    maxFilterPeers,
    maxFilterCriteriaPerPeer,
    messageCacheTTL,
    Opt.some(rateLimitSetting),
  )

  try:
    await self.protocols.filter.start()
  except CatchableError:
    error "failed to start wakuFilter", error = getCurrentExceptionMsg()

  try:
    self.switch.mount(self.protocols.filter, protocolMatcher(WakuFilterSubscribeCodec))
  except LPError:
    error "failed to mount wakuFilter", error = getCurrentExceptionMsg()

proc filterHandleMessage*(
    self: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async.} =
  if self.protocols.filter.isNil():
    debug "Cannot handle filter message", error = "waku filter is required"
    return

  await self.protocols.filter.handleMessage(pubsubTopic, message)

proc mountFilterClient*(self: Kernel) {.async: (raises: []).} =
  ## Mounting both filter
  ## Giving option for application level to choose btw own push message handling or
  ## rely on node provided cache. - This only applies for v2 filter client
  info "mounting filter client"

  if not self.protocols.filterClient.isNil():
    trace "Filter client already mounted."
    return

  self.protocols.filterClient = WakuFilterClient.new(self.peerManager, self.rng)

  try:
    await self.protocols.filterClient.start()
  except CatchableError:
    error "failed to start wakuFilterClient", error = getCurrentExceptionMsg()

  try:
    self.switch.mount(
      self.protocols.filterClient, protocolMatcher(WakuFilterSubscribeCodec)
    )
  except LPError:
    error "failed to mount wakuFilterClient", error = getCurrentExceptionMsg()

proc filterSubscribe*(
    self: Kernel,
    pubsubTopic: Opt[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Registers for messages that match a specific filter. Triggers the handler whenever a message is received.
  if self.protocols.filterClient.isNil():
    debug "Cannot register filter subscription to topic",
      error = "waku filter client is not set up"
    return err(FilterSubscribeError.serviceUnavailable())

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse the peer info properly", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  if pubsubTopic.isSome() and pubsubTopic.get() != "":
    debug "Registering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    when (contentTopics is ContentTopic):
      let contentTopics = @[contentTopics]
    let subRes = await self.protocols.filterClient.subscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if subRes.isOk():
      debug "v2 subscribed to topic",
        pubsubTopic = pubsubTopic, contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      ShardSubscribedEvent.emit(
        self.brokerCtx, ShardSubscribedEvent(topic: pubsubTopic.get())
      )
    else:
      debug "Failed filter v2 subscription", error = subRes.error
      logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])

    return subRes
  elif self.wakuAutoSharding.isNone():
    debug "Failed filter subscription, pubsub topic must be specified with static sharding"
    logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
    return err(
      FilterSubscribeError.badRequest(
        "pubsubTopic must be specified when static sharding is enabled"
      )
    )
  else:
    # No pubsub topic, autosharding is used to deduce it
    # but content topics must be well-formed for this
    let topicMap = self.wakuAutoSharding
      .get()
      .getShardsFromContentTopics(contentTopics).valueOr:
        debug "Can't get shard", error = error
        return err(FilterSubscribeError.badResponse("can't get shard"))

    var futures = collect(newSeq):
      for shard, topics in topicMap.pairs:
        debug "Registering filter subscription to content",
          shard = shard, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        self.protocols.filterClient.subscribe(remotePeer, $shard, content)

    var subRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    try:
      let finished = await allFinished(futures)

      for fut in finished:
        let res = fut.read()

        if res.isErr():
          debug "Failed filter subscription", error = res.error
          logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
          subRes = FilterSubscribeResult.err(res.error)

      for pubsub, topics in topicMap.pairs:
        info "subscribed to topic", pubsubTopic = pubsub, contentTopics = topics

        # Purpose is to update Waku Metadata
        ShardSubscribedEvent.emit(self.brokerCtx, ShardSubscribedEvent(topic: $pubsub))
    except CatchableError:
      let errMsg = "exception in filterSubscribe: " & getCurrentExceptionMsg()
      debug "Exception in filterSubscribe", error = getCurrentExceptionMsg()
      logos_delivery_node_errors.inc(labelValues = ["subscribe_filter_failure"])
      subRes =
        FilterSubscribeResult.err(FilterSubscribeError.serviceUnavailable(errMsg))

    # return the last error or ok
    return subRes

proc filterUnsubscribe*(
    self: Kernel,
    pubsubTopic: Opt[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
    peer: RemotePeerInfo | string,
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Unsubscribe from a content filter V2".

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse remotePeerInfo", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  if pubsubTopic.isSome() and pubsubTopic.get() != "":
    debug "Deregistering filter subscription to content",
      pubsubTopic = pubsubTopic.get(),
      contentTopics = contentTopics,
      peer = remotePeer.peerId

    let unsubRes = await self.protocols.filterClient.unsubscribe(
      remotePeer, pubsubTopic.get(), contentTopics
    )
    if unsubRes.isOk():
      debug "Unsubscribed from topic",
        pubsubTopic = pubsubTopic.get(), contentTopics = contentTopics

      # Purpose is to update Waku Metadata
      ShardUnsubscribedEvent.emit(
        self.brokerCtx, ShardUnsubscribedEvent(topic: pubsubTopic.get())
      )
    else:
      debug "Failed filter unsubscription", error = unsubRes.error
      logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

    return unsubRes
  elif self.wakuAutoSharding.isNone():
    debug "Failed filter un-subscription, pubsub topic must be specified with static sharding"
    logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
    return err(
      FilterSubscribeError.badRequest(
        "pubsubTopic must be specified when static sharding is enabled"
      )
    )
  else: # pubsubTopic.isNone
    let topicMap = self.wakuAutoSharding
      .get()
      .getShardsFromContentTopics(contentTopics).valueOr:
        debug "Can't get shard", error = error
        return err(FilterSubscribeError.badResponse("can't get shard"))

    var futures = collect(newSeq):
      for shard, topics in topicMap.pairs:
        debug "Deregistering filter subscription to content",
          shard = shard, contentTopics = topics, peer = remotePeer.peerId
        let content = topics.mapIt($it)
        self.protocols.filterClient.unsubscribe(remotePeer, $shard, content)

    var unsubRes: FilterSubscribeResult = FilterSubscribeResult.ok()
    try:
      let finished = await allFinished(futures)

      for fut in finished:
        let res = fut.read()

        if res.isErr():
          debug "Failed filter unsubscription", error = res.error
          logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
          unsubRes = FilterSubscribeResult.err(res.error)

      for pubsub, topics in topicMap.pairs:
        debug "Unsubscribed from topic", pubsubTopic = pubsub, contentTopics = topics

        # Purpose is to update Waku Metadata
        ShardUnsubscribedEvent.emit(
          self.brokerCtx, ShardUnsubscribedEvent(topic: $pubsub)
        )
    except CatchableError:
      let errMsg = "exception in filterUnsubscribe: " & getCurrentExceptionMsg()
      debug "Exception in filterUnsubscribe", error = getCurrentExceptionMsg()
      logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])
      unsubRes =
        FilterSubscribeResult.err(FilterSubscribeError.serviceUnavailable(errMsg))

    # return the last error or ok
    return unsubRes

proc filterUnsubscribeAll*(
    self: Kernel, peer: RemotePeerInfo | string
): Future[FilterSubscribeResult] {.async: (raises: []).} =
  ## Unsubscribe from a content filter V2".

  let remotePeer = parsePeerInfo(peer).valueOr:
    debug "Couldn't parse remotePeerInfo", error = error
    return err(FilterSubscribeError.serviceUnavailable("No peers available"))

  debug "Deregistering all filter subscription to content", peer = remotePeer.peerId

  let unsubRes = await self.protocols.filterClient.unsubscribeAll(remotePeer)
  if unsubRes.isOk():
    debug "Unsubscribed from all content-topic", peerId = remotePeer.peerId
  else:
    debug "Failed filter unsubscription from all content-topic", error = unsubRes.error
    logos_delivery_node_errors.inc(labelValues = ["unsubscribe_filter_failure"])

  return unsubRes

# NOTICE: subscribe / unsubscribe methods are removed - they were already depricated
# yet incompatible to handle both type of filters - use specific filter registration instead

const FilterOpTimeout = 5.seconds

proc filterSubscribe*(
    self: Kernel,
    pubsubTopic: PubsubTopic,
    contentTopics: seq[ContentTopic],
    pushHandler: FilterPushHandler,
): Future[Result[bool, string]] {.async.} =
  ## Registers `pushHandler` for incoming filtered messages, selects a filter
  ## service peer, and subscribes.
  try:
    if self.protocols.filterClient.isNil():
      return err("wakuFilterClient is not mounted")

    self.protocols.filterClient.registerPushHandler(pushHandler)

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when subscribing")

    let subFut = self.filterSubscribe(Opt.some(pubsubTopic), contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      return err("filter subscription timed out")
    subFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribe*(
    self: Kernel, pubsubTopic: PubsubTopic, contentTopics: seq[ContentTopic]
): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes the given content topics.
  try:
    if self.protocols.filterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return err("could not find peer with WakuFilterSubscribeCodec when unsubscribing")

    let unsubFut = self.filterUnsubscribe(Opt.some(pubsubTopic), contentTopics, peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc filterUnsubscribeAll*(self: Kernel): Future[Result[bool, string]] {.async.} =
  ## Selects a filter service peer and unsubscribes from everything.
  try:
    if self.protocols.filterClient.isNil():
      return err("wakuFilterClient is not mounted")

    let peer = self.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      return
        err("could not find peer with WakuFilterSubscribeCodec when unsubscribing all")

    let unsubFut = self.filterUnsubscribeAll(peer)
    if not await unsubFut.withTimeout(FilterOpTimeout):
      return err("filter un-subscription all timed out")
    unsubFut.read().isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)
