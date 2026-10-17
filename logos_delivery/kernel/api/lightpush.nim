## Waku layer API — lightpush (light client publish) operations.
{.push raises: [].}

import
  std/[hashes, strutils, tables, net],
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
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/builders,
  libp2p/transports/tcptransport,
  libp2p/transports/wstransport,
  libp2p/stream/connection,
  libp2p_mix

import
  logos_delivery/kernel/kernel,
  logos_delivery/kernel/core/[
    topics/content_topic,
    topics/pubsub_topic,
    topics/sharding,
    topics/content_topic,
    topics/pubsub_topic,
    topics/sharding,
    message,
    peers,
  ],
  logos_delivery/kernel/protocols/codecs,
  logos_delivery/kernel/core/topics/sharding,
  logos_delivery/kernel/protocols/lightpush_legacy/client as legacy_lightpush_client,
  logos_delivery/kernel/protocols/lightpush_legacy/callbacks as
    legacy_lightpush_callbacks,
  logos_delivery/kernel/protocols/lightpush_legacy/common as legacy_lightpush_common,
  logos_delivery/kernel/protocols/lightpush_legacy/[protocol, self_req_handler],
  logos_delivery/kernel/protocols/lightpush/client as lightpush_client,
  logos_delivery/kernel/protocols/lightpush/callbacks as lightpush_callbacks,
  logos_delivery/kernel/protocols/lightpush/common as lightpush_common,
  logos_delivery/kernel/protocols/lightpush/[protocol, rpc, self_req_handler],
  logos_delivery/kernel/node/peer_manager/peer_manager,
  logos_delivery/kernel/common/rate_limit/setting,
  logos_delivery/kernel/
    [rln/markers, rln/rln_evm/group_manager, rln/rln_evm/conversion_utils],
  logos_delivery/kernel/rln/rln_plugin
from logos_delivery/kernel/rln/types import RlnErrorKind

logScope:
  topics = "waku node lightpush api"

import results, chronos, chronicles

import
  logos_delivery/kernel/[
    core/topics/pubsub_topic,
    core/message,
    protocols/codecs,
    node/peer_manager/peer_manager,
    protocols/lightpush_legacy/client,
  ]

const MountWithoutRelayError* = "cannot mount lightpush because relay is not mounted"

const MixReplyTimeout* = chronos.seconds(5)
  ## Time limit for one mix-routed lightpush, so a broken path costs one
  ## attempt.

proc publishOverMix*(
    node: Kernel,
    conn: Connection,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
    replyTimeout: Duration = MixReplyTimeout,
): Future[lightpush_common.WakuLightPushResult] {.async.} =
  ## Publishes on a mix connection and returns within `replyTimeout`. The mix
  ## connection limits its wait for the reply, but not the first-hop dial.
  let publishFut =
    node.protocols.lightPushClient.publish(Opt.some(pubsubTopic), message, conn)
  let deadline = sleepAsync(replyTimeout)
  discard await race(FutureBase(publishFut), FutureBase(deadline))

  if not publishFut.finished():
    await conn.reset()
    publishFut.cancelSoon()
    debug "Mix lightpush timed out", pubsubTopic = pubsubTopic, timeout = replyTimeout
    return lighpushErrorResult(
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, "Waku lightpush over mix timed out"
    )

  await deadline.cancelAndWait()
  return await publishFut

## Waku lightpush
proc mountLegacyLightPush*(
    node: Kernel, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
): Future[Result[void, string]] {.async.} =
  info "mounting legacy light push"

  if node.protocols.relay.isNil():
    return err(MountWithoutRelayError)

  info "mounting legacy lightpush with relay"
  let pushHandler = legacy_lightpush_callbacks.getRelayPushHandler(node.protocols.relay)

  node.protocols.legacyLightPush = WakuLegacyLightPush.new(
    node.peerManager,
    node.rng,
    pushHandler,
    Opt.some(rateLimit),
    node.protocols.relay.maxMessageSize,
  )

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.protocols.legacyLightPush.start()

  node.switch.mount(
    node.protocols.legacyLightPush, protocolMatcher(WakuLegacyLightPushCodec)
  )

  debug "legacy lightpush mounted successfully"
  return ok()

proc mountLegacyLightPushClient*(node: Kernel) =
  info "mounting legacy light push client"

  if node.protocols.legacyLightPushClient.isNil():
    node.protocols.legacyLightPushClient =
      WakuLegacyLightPushClient.new(node.peerManager, node.rng)

proc internalLegacyLightpushPublish(
    node: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage, peer: RemotePeerInfo
): Future[legacy_lightpush_common.WakuLightPushResult[string]] {.async, gcsafe.} =
  ## Dispatches to the legacy lightpush client if mounted, otherwise to the
  ## self-hosted server. Callers guarantee at least one is mounted.
  let msgHash = pubsubTopic.computeMessageHash(message).to0xHex()
  if not node.protocols.legacyLightPushClient.isNil():
    debug "Publishing message with legacy lightpush",
      pubsubTopic = pubsubTopic,
      contentTopic = message.contentTopic,
      target_peer_id = peer.peerId,
      msg_hash = msgHash
    return
      await node.protocols.legacyLightPushClient.publish(pubsubTopic, message, peer)

  debug "Publishing message with self hosted legacy lightpush",
    pubsubTopic = pubsubTopic,
    contentTopic = message.contentTopic,
    target_peer_id = peer.peerId,
    msg_hash = msgHash
  return await node.protocols.legacyLightPush.handleSelfLightPushRequest(
    pubsubTopic, message
  )

proc resolveLegacyPubsubTopic(
    node: Kernel, pubsubTopic: Opt[PubsubTopic], contentTopic: ContentTopic
): Result[PubsubTopic, string] =
  ## Returns the explicit pubsub topic, else derives it from `contentTopic`
  ## via autosharding. The legacy wire format requires a pubsub topic and the
  ## server never derives it, so the client must resolve it here.
  if pubsubTopic.isSome():
    return ok(pubsubTopic.get())
  if node.wakuAutoSharding.isNone():
    return err("Pubsub topic must be specified when static sharding is enabled")
  let parsedTopic = NsContentTopic.parse(contentTopic).valueOr:
    return err("Invalid content-topic: " & $error)
  let shard = node.wakuAutoSharding.get().getShard(parsedTopic).valueOr:
      return err("Autosharding error: " & error)
  return ok($shard)

proc legacyLightpushPublish*(
    node: Kernel,
    pubsubTopic: Opt[PubsubTopic],
    message: WakuMessage,
    peer: RemotePeerInfo,
): Future[legacy_lightpush_common.WakuLightPushResult[string]] {.async, gcsafe.} =
  ## Pushes a `WakuMessage` to a node which relays it further on PubSub topic.
  ## Returns whether relaying was successful or not.
  ## `WakuMessage` should contain a `contentTopic` field for light node
  ## functionality.
  if node.protocols.legacyLightPushClient.isNil() and
      node.protocols.legacyLightPush.isNil():
    debug "Failed to publish message as legacy lightpush not available"
    return err("Waku lightpush not available")

  # toRLNSignal hashes the timestamp into the proof, so fix it before proof gen;
  # the downstream ensureTimestampSet then becomes a no-op.
  let message = ensureTimestampSet(message)

  let msgWithProof = (await attachProof(node.protocols.rlnPlugin, message)).valueOr:
    return err("failed to attach RLN proof: " & $error)

  try:
    let pubsubForPublish = resolveLegacyPubsubTopic(
      node, pubsubTopic, message.contentTopic
    ).valueOr:
      return err(error)

    let publishResult =
      await internalLegacyLightpushPublish(node, pubsubForPublish, msgWithProof, peer)

    # Legacy has no status codes, so string-match the RLN error to detect a
    # rejected proof. Ask the backend to refresh what proofs are built against
    # and hand the error back: retrying is the caller's decision, the same way
    # the non-legacy path behaves. A backend without a refresh hook gets the
    # error back unchanged.
    if publishResult.isOk() or not publishResult.error.contains(RlnValidatorErrorMsg):
      return publishResult
    if not node.protocols.rlnPlugin.notifyProofRejected():
      return publishResult

    debug "legacy lightpush send rejected as RLN-invalid; RLN proof refresh scheduled"
    return err(RlnProofRefreshScheduledMsg & ": " & publishResult.error)
  except CatchableError:
    return err(getCurrentExceptionMsg())

# TODO: Move to application module (e.g., logosdeliverynode.nim)
proc legacyLightpushPublish*(
    node: Kernel, pubsubTopic: Opt[PubsubTopic], message: WakuMessage
): Future[legacy_lightpush_common.WakuLightPushResult[string]] {.
    async, gcsafe, deprecated: "Use 'node.legacyLightpushPublish()' instead"
.} =
  if node.protocols.legacyLightPushClient.isNil() and
      node.protocols.legacyLightPush.isNil():
    debug "Failed to publish message as legacy lightpush not available"
    return err("waku legacy lightpush not available")

  var peerOpt: Opt[RemotePeerInfo] = Opt.none(RemotePeerInfo)
  if not node.protocols.legacyLightPushClient.isNil():
    peerOpt = node.peerManager.selectPeer(WakuLegacyLightPushCodec)
    if peerOpt.isNone():
      let msg = "no suitable remote peers"
      debug "Failed to publish message", err = msg
      return err(msg)
  elif not node.protocols.legacyLightPush.isNil():
    peerOpt = Opt.some(RemotePeerInfo.init($node.switch.peerInfo.peerId))

  return await node.legacyLightpushPublish(pubsubTopic, message, peer = peerOpt.get())

proc mountLightPush*(
    node: Kernel, rateLimit: RateLimitSetting = DefaultGlobalNonRelayRateLimit
): Future[Result[void, string]] {.async.} =
  info "mounting light push"

  if node.protocols.relay.isNil():
    return err(MountWithoutRelayError)

  info "mounting lightpush with relay"
  let pushHandler = lightpush_callbacks.getRelayPushHandler(node.protocols.relay)

  node.protocols.lightPush = WakuLightPush.new(
    node.peerManager,
    node.rng,
    pushHandler,
    node.wakuAutoSharding,
    Opt.some(rateLimit),
    node.protocols.relay.maxMessageSize,
  )

  if node.started:
    # Node has started already. Let's start lightpush too.
    await node.protocols.lightPush.start()

  node.switch.mount(node.protocols.lightPush, protocolMatcher(WakuLightPushCodec))

  debug "lightpush mounted successfully"
  return ok()

proc mountLightPushClient*(node: Kernel) =
  info "mounting light push client"

  if node.protocols.lightPushClient.isNil():
    node.protocols.lightPushClient = WakuLightPushClient.new(node.peerManager, node.rng)

proc lightpushPublishHandler(
    node: Kernel,
    pubsubTopic: PubsubTopic,
    message: WakuMessage,
    peer: RemotePeerInfo | PeerInfo,
    mixify: bool = false,
): Future[lightpush_common.WakuLightPushResult] {.async.} =
  let msgHash = pubsubTopic.computeMessageHash(message).to0xHex()
  # The client is always mounted alongside the service, and it cannot dial
  # this node's own peer id.
  let toSelf =
    not node.protocols.lightPush.isNil() and peer.peerId == node.peerId() and not mixify
  if not node.protocols.lightPushClient.isNil() and not toSelf:
    debug "Publishing message with lightpush",
      pubsubTopic = pubsubTopic,
      contentTopic = message.contentTopic,
      target_peer_id = peer.peerId,
      msg_hash = msgHash,
      mixify = mixify
    if mixify:
      when defined(libp2p_mix_experimental_exit_is_dest):
        #TODO: How to handle multiple addresses?
        let conn = node.protocols.mix.toConnection(
          MixDestination.exitNode(peer.peerId),
          WakuLightPushCodec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
            # indicating we only want a single path to be used for reply hence numSurbs = 1
        ).valueOr:
          debug "Could not create mix connection"
          return lighpushErrorResult(
            LightPushErrorCode.SERVICE_NOT_AVAILABLE,
            "Waku lightpush with mix not available",
          )

        return await node.publishOverMix(conn, pubsubTopic, message)
      else:
        # Fail the build here, not every mixed send at runtime
        {.error: "mix sends need -d:libp2p_mix_experimental_exit_is_dest".}
    else:
      return await node.protocols.lightPushClient.publish(
        Opt.some(pubsubTopic), message, peer
      )

  if not node.protocols.lightPush.isNil():
    if mixify:
      debug "Mixify is not supported with self hosted lightpush"
      return lighpushErrorResult(
        LightPushErrorCode.SERVICE_NOT_AVAILABLE,
        "Waku lightpush with mix not available",
      )
    debug "Publishing message with self hosted lightpush",
      pubsubTopic = pubsubTopic,
      contentTopic = message.contentTopic,
      target_peer_id = peer.peerId,
      msg_hash = msgHash
    return await node.protocols.lightPush.handleSelfLightPushRequest(
      Opt.some(pubsubTopic), message
    )

proc lightpushPublish*(
    node: Kernel,
    pubsubTopic: Opt[PubsubTopic],
    message: WakuMessage,
    peerOpt: Opt[RemotePeerInfo] = Opt.none(RemotePeerInfo),
    mixify: bool = false,
): Future[lightpush_common.WakuLightPushResult] {.async.} =
  if node.protocols.lightPushClient.isNil() and node.protocols.lightPush.isNil():
    debug "Failed to publish message as lightpush not available"
    return lighpushErrorResult(
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, "Waku lightpush not available"
    )
  if mixify and node.protocols.mix.isNil():
    debug "Failed to publish message using mix as mix protocol is not mounted"
    return lighpushErrorResult(
      LightPushErrorCode.SERVICE_NOT_AVAILABLE, "Waku lightpush with mix not available"
    )
  let toPeer: RemotePeerInfo = peerOpt.valueOr:
    if not node.protocols.lightPush.isNil():
      RemotePeerInfo.init(node.peerId())
    elif not node.protocols.lightPushClient.isNil():
      node.peerManager.selectPeer(WakuLightPushCodec).valueOr:
        let msg = "no suitable remote peers"
        debug "Failed to publish message", msg = msg
        return lighpushErrorResult(LightPushErrorCode.NO_PEERS_TO_RELAY, msg)
    else:
      return lighpushErrorResult(
        LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
      )

  let pubsubForPublish = pubsubTopic.valueOr:
    if node.wakuAutoSharding.isNone():
      let msg = "Pubsub topic must be specified when static sharding is enabled"
      debug "Lightpush publish error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, msg)

    let parsedTopic = NsContentTopic.parse(message.contentTopic).valueOr:
      let msg = "Invalid content-topic:" & $error
      debug "Lightpush request handling error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, msg)

    node.wakuAutoSharding.get().getShard(parsedTopic).valueOr:
      let msg = "Autosharding error: " & error
      debug "Lightpush publish error", error = msg
      return lighpushErrorResult(LightPushErrorCode.INTERNAL_SERVER_ERROR, msg)

  # toRLNSignal hashes the timestamp into the proof, so fix it before proof gen;
  # the downstream ensureTimestampSet then becomes a no-op.
  let message = ensureTimestampSet(message)

  # A Permanent failure comes from the message itself, such as a timestamp
  # outside the validators' bound, so it is the client's INVALID_MESSAGE, as
  # the relay validator answered before proof generation checked it. Any
  # other failure is the node's: it has no proof to offer right now.
  let msgWithProof = (await attachProof(node.protocols.rlnPlugin, message)).valueOr:
    let code =
      if error.kind == RlnErrorKind.Permanent:
        LightPushErrorCode.INVALID_MESSAGE
      else:
        LightPushErrorCode.OUT_OF_RLN_PROOF
    return lighpushErrorResult(code, "failed to attach RLN proof: " & $error)

  let firstResult =
    await lightpushPublishHandler(node, pubsubForPublish, msgWithProof, toPeer, mixify)

  # Gate the refresh on unambiguously RLN-related failures: 504
  # (OUT_OF_RLN_PROOF) is always RLN; 420 (INVALID_MESSAGE) also covers non-RLN
  # rejections (e.g. oversized), so additionally require RlnValidatorErrorMsg.
  if firstResult.isOk():
    return firstResult
  let isRlnRelatedFailure =
    firstResult.error.code == LightPushErrorCode.OUT_OF_RLN_PROOF or (
      firstResult.error.code == LightPushErrorCode.INVALID_MESSAGE and
      firstResult.error.desc.get("").contains(RlnValidatorErrorMsg)
    )
  if not isRlnRelatedFailure:
    return firstResult

  # Ask the backend to refresh what proofs are built against and return
  # immediately, normalized to 504 with RlnProofRefreshScheduledMsg so callers
  # can tell "stale proof, retry" from a permanent rejection. A backend without
  # a refresh hook gets the result back unchanged.
  if not node.protocols.rlnPlugin.notifyProofRejected():
    return firstResult
  debug "lightpush send rejected as RLN-invalid; RLN proof refresh scheduled",
    statusCode = $firstResult.error.code
  return lighpushErrorResult(
    LightPushErrorCode.OUT_OF_RLN_PROOF,
    RlnProofRefreshScheduledMsg & ": " &
      firstResult.error.desc.get($firstResult.error.code),
  )

proc lightpushPublish*(
    self: Kernel, pubsubTopic: PubsubTopic, message: WakuMessage
): Future[Result[string, string]] {.async.} =
  ## Selects a lightpush service peer and publishes; returns the message hash.
  try:
    if self.protocols.legacyLightPushClient.isNil():
      return err("wakuLegacyLightpushClient is not mounted")

    let remotePeer = self.peerManager.selectPeer(WakuLightPushCodec).valueOr:
      return err("failed to lightpublish message, no suitable remote peers")

    let msgHashHex = (
      await self.protocols.legacyLightPushClient.publish(
        pubsubTopic, message, remotePeer
      )
    ).valueOr:
      return err($error)

    return ok(msgHashHex)
  except CatchableError as e:
    return err(e.msg)
