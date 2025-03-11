{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid
import
  ../waku_core/peers,
  ../node/peer_manager,
  ../node/delivery_monitor/publish_observer,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec,
  ../incentivization/reputation_manager

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  peerManager*: PeerManager
  rng*: ref rand.HmacDrbgContext
  reputationManager*: Option[ReputationManager]
  publishObservers: seq[PublishObserver]

proc new*(
    T: type WakuLightPushClient,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    reputationEnabled: bool,
): T =
  let reputationManager =
    if reputationEnabled:
      some(ReputationManager.new())
    else:
      none(ReputationManager)
  WakuLightPushClient(
    peerManager: peerManager, rng: rng, reputationManager: reputationManager
  )

proc addPublishObserver*(wl: WakuLightPushClient, obs: PublishObserver) =
  wl.publishObservers.add(obs)

proc sendPushRequest(
    wl: WakuLightPushClient, req: LightPushRequest, peer: PeerId | RemotePeerInfo
): Future[WakuLightPushResult] {.async.} =
  let connection = (await wl.peerManager.dialPeer(peer, WakuLightPushCodec)).valueOr:
    waku_lightpush_v3_errors.inc(labelValues = [dialFailure])
    return lighpushErrorResult(
      NO_PEERS_TO_RELAY, dialFailure & ": " & $peer & " is not accessible"
    )

  await connection.writeLP(req.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    error "Failed to read responose from peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to read response from peer: " & getCurrentExceptionMsg()
    )

  let response = LightpushResponse.decode(buffer).valueOr:
    error "failed to decode response"
    waku_lightpush_v3_errors.inc(labelValues = [decodeRpcFailure])
    return lightpushResultInternalError(decodeRpcFailure)

  if response.requestId != req.requestId and
      response.statusCode != TOO_MANY_REQUESTS.uint32:
    error "response failure, requestId mismatch",
      requestId = req.requestId, responseRequestId = response.requestId
    return lightpushResultInternalError("response failure, requestId mismatch")

  if wl.reputationManager.isSome:
    wl.reputationManager.get().updateReputationFromResponse(peer.peerId, response)

  return toPushResult(response)

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: Option[PubsubTopic] = none(PubsubTopic),
    message: WakuMessage,
    peer: PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  when peer is PeerId:
    info "publish",
      peerId = shortLog(peer),
      msg_hash = computeMessageHash(pubsubTopic.get(""), message).to0xHex
  else:
    info "publish",
      peerId = shortLog(peer.peerId),
      msg_hash = computeMessageHash(pubsubTopic.get(""), message).to0xHex

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubSubTopic: pubSubTopic, message: message
  )
  let publishedCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic.get(""), message)

  # FIXME: where is negative result returned?
  # we should check publish result for adjusting reputation
  # but it's unclear where to check it, hence checking publishedCount
  if publishedCount == 0:
    if wl.reputationManager.isSome:
      wl.reputationManager.get().setReputation(peer.peerId, some(false))

  return lightpushSuccessResult(publishedCount)

# TODO: move selectPeerForLightPush logic into PeerManager
proc selectPeerForLightPush*(
    wl: WakuLightPushClient
): Future[Result[RemotePeerInfo, string]] {.async, gcsafe.} =
  let maxAttempts = if defined(reputation): 10 else: 1
  var attempts = 0
  var peerResult: Result[RemotePeerInfo, string]
  while attempts < maxAttempts:
    let candidate = wl.peerManager.selectPeer(WakuLightPushCodec, none(PubsubTopic)).valueOr:
      return err("could not retrieve a peer supporting WakuLightPushCodec")
    if wl.reputationManager.isSome():
      let reputation = wl.reputationManager.get().getReputation(candidate.peerId)
      info "Peer selected",
        peerId = candidate.peerId, reputation = $reputation, attempts = $attempts
      if (reputation == some(false)):
        attempts += 1
        continue
    return ok(candidate)
  warn "Maximum reputation-based retries exceeded; continuing with a bad-reputation peer."
  return peerResult

proc publishToAny*(
    wl: WakuLightPushClient, pubSubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult] {.async, gcsafe.} =
  ## This proc is similar to the publish one but in this case
  ## we don't specify a particular peer and instead we get it from peer manager

  info "publishToAny", msg_hash = computeMessageHash(pubsubTopic, message).to0xHex
  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    # TODO: check if it is matches the situation - shall we distinguish client side missing peers from server side?
    return lighpushErrorResult(NO_PEERS_TO_RELAY, "no suitable remote peers")

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng),
    pubSubTopic: some(pubSubTopic),
    message: message,
  )
  let publishedCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return lightpushSuccessResult(publishedCount)
