## Waku layer API — relay (gossipsub) operations.
{.push raises: [].}

import
  std/net,
  chronos,
  chronicles,
  metrics,
  results,
  stew/byteutils,
  eth/keys,
  eth/p2p/discoveryv5/enr,
  libp2p/crypto/crypto,
  libp2p/protocols/ping,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/pubsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  brokers/broker_context

import
  logos_delivery/kernel/[
    protocols/relay/protocol as relay_protocol,
    node/health_monitor/topic_health,
    core/topics,
    core/topics/content_topic,
    core/topics/pubsub_topic,
    core/topics/sharding,
    core/time,
    core/message,
    protocols/codecs,
    rln/markers,
    rln/protocol_metrics,
    rln/rln_plugin,
    kernel,
    node/subscription_manager,
    node/peer_manager/peer_manager,
    rln/types,
  ]
import logos_delivery/api/events/kernel_events # MessageSeenEvent

export relay_protocol.WakuRelayHandler

logScope:
  topics = "waku node relay api"

## Waku relay

import std/sequtils
import results, chronos, chronicles, secp256k1, stew/byteutils

import
  logos_delivery/kernel/[
    core/topics,
    core/topics/pubsub_topic,
    core/message,
    protocols/relay/protocol,
    factory/waku_conf,
    factory/validator_signed,
  ]

proc getTopicOfSubscriptionEvent(
    node: Kernel, subscription: SubscriptionEvent
): Result[(PubsubTopic, Opt[ContentTopic]), string] =
  case subscription.kind
  of ContentSub, ContentUnsub:
    if node.wakuAutoSharding.isSome():
      let shard = node.wakuAutoSharding.get().getShard((subscription.topic)).valueOr:
          return err("Autosharding error: " & error)
      return ok(($shard, Opt.some(subscription.topic)))
    else:
      return
        err("Static sharding is used, relay subscriptions must specify a pubsub topic")
  of PubsubSub, PubsubUnsub:
    return ok((subscription.topic, Opt.none(ContentTopic)))
  else:
    return err("Unsupported subscription type in relay getTopicOfSubscriptionEvent")

proc subscribe*(
    node: Kernel, subscription: SubscriptionEvent, handler: WakuRelayHandler
): Result[void, string] =
  ## Subscribes to a PubSub or Content topic. Triggers handler when receiving messages on
  ## this topic. WakuRelayHandler is a method that takes a topic and a Waku message.
  ## If `handler` is nil, the API call will subscribe to the topic in the relay mesh
  ## but no app handler will be registered at this time (it can be registered later with
  ## another call to this proc for the same gossipsub topic).

  if isNil(node.protocols.relay):
    debug "Invalid API call to `subscribe`. WakuRelay not mounted."
    return err("Invalid API call to `subscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  # strict version
  #if contentTopicOp.isSome():
  #  return
  #    node.subscriptionManager.subscribe(pubsubTopic, contentTopicOp.get(), handler)
  return node.subscriptionManager.subscribeShard(pubsubTopic, handler)

proc unsubscribe*(node: Kernel, subscription: SubscriptionEvent): Result[void, string] =
  ## Unsubscribes from a specific PubSub or Content topic.
  ## This will both unsubscribe from the relay mesh and remove the app handler, if any.
  ## NOTE: This works because using MAPI and Kernel API at the same time is unsupported.

  if isNil(node.protocols.relay):
    debug "Invalid API call to `unsubscribe`. WakuRelay not mounted."
    return err("Invalid API call to `unsubscribe`. WakuRelay not mounted.")

  let (pubsubTopic, _) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode unsubscribe event", error = error
    return err("Failed to decode unsubscribe event: " & error)

  # strict version
  #if contentTopicOp.isSome():
  #  return node.subscriptionManager.unsubscribe(pubsubTopic, contentTopicOp.get())
  return node.subscriptionManager.unsubscribeAll(pubsubTopic)

proc isSubscribed*(
    node: Kernel, subscription: SubscriptionEvent
): Result[bool, string] =
  if node.protocols.relay.isNil():
    debug "Invalid API call to `isSubscribed`. WakuRelay not mounted."
    return err("Invalid API call to `isSubscribed`. WakuRelay not mounted.")

  let (pubsubTopic, contentTopicOp) = getTopicOfSubscriptionEvent(node, subscription).valueOr:
    debug "Failed to decode subscription event", error = error
    return err("Failed to decode subscription event: " & error)

  return ok(node.protocols.relay.isSubscribed(pubsubTopic))

proc publish*(
    node: Kernel, pubsubTopicOp: Opt[PubsubTopic], message: WakuMessage
): Future[Result[int, string]] {.async, gcsafe.} =
  ## Publish a `WakuMessage`. Pubsub topic contains; none, a named or static shard.
  ## `WakuMessage` should contain a `contentTopic` field for light node functionality.
  ## It is also used to determine the shard.

  if node.protocols.relay.isNil():
    let msg =
      "Invalid API call to `publish`. WakuRelay not mounted. Try `lightpush` instead."
    debug "Publish error", err = msg
    # TODO: Improve error handling
    return err(msg)

  let pubsubTopic = pubsubTopicOp.valueOr:
    if node.wakuAutoSharding.isNone():
      return err("Pubsub topic must be specified when static sharding is enabled.")
    node.wakuAutoSharding.get().getShard(message.contentTopic).valueOr:
      let msg = "Autosharding error: " & error
      return err(msg)

  let numPeers = (await node.protocols.relay.publish(pubsubTopic, message)).valueOr:
    debug "waku.relay did not publish", error = error
    # Todo: If NoPeersToPublish, we might want to return ok(0) instead!!!
    return err("publish failed in relay: " & $error)

  debug "waku.relay published",
    peerId = node.peerId,
    pubsubTopic = pubsubTopic,
    msg_hash = pubsubTopic.computeMessageHash(message).to0xHex(),
    publishTime = getNowInNanosecondTime(),
    numPeers = numPeers

  # TODO: investigate if we can return error in case numPeers is 0
  ok(numPeers)

proc mountRelay*(
    node: Kernel,
    peerExchangeHandler = Opt.none(RoutingRecordsHandler),
    maxMessageSize = int(DefaultMaxWakuMessageSize),
): Future[Result[void, string]] {.async.} =
  if not node.protocols.relay.isNil():
    debug "wakuRelay already mounted, skipping"
    return err("wakuRelay already mounted, skipping")

  ## The default relay topics is the union of all configured topics plus default PubsubTopic(s)
  info "mounting relay protocol"

  node.protocols.relay = WakuRelay.new(node.switch, maxMessageSize).valueOr:
    error "failed mounting relay protocol", error = error
    return err("failed mounting relay protocol: " & error)

  ## Add peer exchange handler
  if peerExchangeHandler.isSome():
    node.protocols.relay.parameters.enablePX = true
      # Feature flag for peer exchange in nim-libp2p
    node.protocols.relay.routingRecordsHandler.add(peerExchangeHandler.get())

  if node.started:
    await node.protocols.relay.start()
    await node.reconnectRelayPeers()

  node.switch.mount(node.protocols.relay, protocolMatcher(WakuRelayCodec))

  debug "relay mounted successfully"
  return ok()

  ## Waku RLN Relay

proc registerRlnValidator(
    node: Kernel,
    plugin: RlnPlugin,
    commonConf: RlnCommonConf,
    spamHandler = Opt.none(SpamHandler),
) =
  ## Registers the backend-agnostic RLN message validator. Verdicts come from
  ## the mounted backend's `validateProof`; the validator never names a backend.
  info "Setting rln validator"

  if node.protocols.relay.isNil():
    info "WakuRelay not mounted; RLN validator not set"
    return

  if commonConf.disableValidation:
    # Temporary RLN phase-in: published messages still carry proofs, but
    # received messages pass through unchecked.
    info "RLN proof validation is disabled; not registering the RLN validator"
    return

  let validateProof = plugin.validateProof
  if validateProof.isNil():
    info "RLN backend has no proof validation; RLN validator not set"
    return

  proc validator(
      topic: string, message: WakuMessage
  ): Future[pubsub.ValidationResult] {.async.} =
    trace "RLN topic validator is called"

    let res = (await validateProof(message)).valueOr:
      # no verdict from the backend — don't score the peer down for our own failure
      trace "RLN validator ignore", error = $error
      return pubsub.ValidationResult.Ignore

    let proof = byteutils.toHex(message.proof)
    case res.verdict
    of ProofVerdict.Valid:
      trace "Message validity is verified, relaying", proof = proof
      logos_delivery_rln_valid_messages_total.inc(labelValues = [topic])
      return pubsub.ValidationResult.Accept
    of ProofVerdict.Invalid:
      trace "Message validity could not be verified, discarding", proof = proof
      return pubsub.ValidationResult.Reject
    of ProofVerdict.Duplicate:
      trace "Duplicate rln proof, discarding", proof = proof
      return pubsub.ValidationResult.Reject
    of ProofVerdict.RateLimitViolation:
      trace "Rate limit violation found, discarding", proof = proof
      if spamHandler.isSome():
        let handler = spamHandler.get()
        handler(message)
      return pubsub.ValidationResult.Reject

  debug "Registering RLN validator"
  node.protocols.relay.addValidator(validator, RlnValidatorErrorMsg)

proc mountRln*(
    node: Kernel,
    plugin: RlnPlugin,
    commonConf: RlnCommonConf,
    spamHandler = Opt.none(SpamHandler),
) =
  ## Mounts an RLN backend on `node`: records its plugin and registers the
  ## RLN relay validator.
  node.protocols.rlnPlugin = Opt.some(plugin)
  node.registerRlnValidator(plugin, commonConf, spamHandler)

proc relayPublish*(
    self: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage, timeoutMs: uint32
): Future[Result[string, string]] {.async.} =
  ## Publishes `message` and returns its message hash (0x-hex).
  try:
    if self.protocols.relay.isNil():
      return err("relayPublish: WakuRelay not mounted")

    (await self.protocols.relay.publish(pubsubTopic, message)).isOkOr:
      return err($error)

    return ok(computeMessageHash(pubsubTopic, message).to0xHex)
  except CatchableError as e:
    return err(e.msg)

proc relaySubscribe*(
    self: Kernel,
    pubsubTopic: PubsubTopic,
    handler: WakuRelayHandler = WakuRelayHandler(nil),
): Future[Result[bool, string]] {.async.} =
  ## Subscribes to `pubsubTopic`. `handler` (optional) is invoked per message;
  ## pass nil to subscribe without a message callback.
  try:
    if self.protocols.relay.isNil():
      return err("relaySubscribe: WakuRelay not mounted")

    self.subscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic), handler).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayUnsubscribe*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[bool, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayUnsubscribe: WakuRelay not mounted")

    self.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: pubsubTopic)).isOkOr:
      return err($error)

    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayAddProtectedShard*(
    self: Kernel, clusterId: uint16, shardId: uint16, publicKey: string
): Future[Result[bool, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayAddProtectedShard: WakuRelay not mounted")

    let pubKey = SkPublicKey.fromHex(publicKey).valueOr:
      return err("relayAddProtectedShard: invalid public key: " & $error)

    let protectedShard = ProtectedShard(shard: shardId, key: pubKey)
    self.protocols.relay.addSignedShardsValidator(@[protectedShard], clusterId)
    return ok(true)
  except CatchableError as e:
    return err(e.msg)

proc relayConnectedPeers*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayConnectedPeers: WakuRelay not mounted")

    let connPeers = self.protocols.relay.getConnectedPeers(pubsubTopic).valueOr:
      return err($error)

    return ok(connPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayPeersInMesh*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[seq[string], string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayPeersInMesh: WakuRelay not mounted")

    let meshPeers = self.protocols.relay.getPeersInMesh(pubsubTopic).valueOr:
      return err($error)

    return ok(meshPeers.mapIt($it))
  except CatchableError as e:
    return err(e.msg)

proc relayNumPeersInMesh*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayNumPeersInMesh: WakuRelay not mounted")
    let n = self.protocols.relay.getNumPeersInMesh(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)

proc relayNumConnectedPeers*(
    self: Kernel, pubsubTopic: PubsubTopic
): Future[Result[int, string]] {.async.} =
  try:
    if self.protocols.relay.isNil():
      return err("relayNumConnectedPeers: WakuRelay not mounted")
    let n = self.protocols.relay.getNumConnectedPeers(pubsubTopic).valueOr:
      return err($error)
    return ok(n)
  except CatchableError as e:
    return err(e.msg)
