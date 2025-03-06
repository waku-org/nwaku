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
    wl: WakuLightPushClient, req: PushRequest, peer: PeerId | RemotePeerInfo
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)
  let connection = connOpt.get()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: some(req))
  await connection.writeLP(rpc.encode().buffer)

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    return err("Exception reading: " & getCurrentExceptionMsg())

  let decodeRespRes = PushRPC.decode(buffer)
  if decodeRespRes.isErr():
    error "failed to decode response"
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return err(decodeRpcFailure)

  let pushResponseRes = decodeRespRes.get()
  if pushResponseRes.response.isNone():
    waku_lightpush_errors.inc(labelValues = [emptyResponseBodyFailure])
    return err(emptyResponseBodyFailure)

  let response = pushResponseRes.response.get()
  if not response.isSuccess:
    if response.info.isSome():
      return err(response.info.get())
    else:
      return err("unknown failure")

  if wl.reputationManager.isSome:
    wl.reputationManager.get().updateReputationFromResponse(peer.peerId, response)

  return ok()

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: PubsubTopic,
    message: WakuMessage,
    peer: RemotePeerInfo,
): Future[WakuLightPushResult[string]] {.async, gcsafe.} =
  ## On success, returns the msg_hash of the published message
  let msg_hash = computeMessageHash(pubsubTopic, message).to0xHex()

  let pushRequest = PushRequest(pubSubTopic: pubSubTopic, message: message)
  let pushResult = await wl.sendPushRequest(pushRequest, peer)
  if pushResult.isErr:
    if wl.reputationManager.isSome:
      wl.reputationManager.get().setReputation(peer.peerId, some(false))
    return err(pushResult.error)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  notice "publishing message with lightpush",
    pubsubTopic = pubSubTopic,
    contentTopic = message.contentTopic,
    target_peer_id = peer.peerId,
    msg_hash = msg_hash

  return ok(msg_hash)

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
      info "Peer selected", peerId = candidate.peerId, reputation = $reputation, attempts = $attempts
      if (reputation == some(false)):
        attempts += 1
        continue
    return ok(candidate)
  warn "Maximum reputation-based retries exceeded; continuing with a bad-reputation peer."
  return peerResult

proc publishToAny*(
    wl: WakuLightPushClient, pubSubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[string]] {.async, gcsafe.} =
  info "publishToAny", msg_hash = computeMessageHash(pubSubTopic, message).to0xHex
  let peer = ?await wl.selectPeerForLightPush()
  let publishResult = await wl.publish(pubSubTopic, message, peer)
  info "Publish result", result = $publishResult
  return publishResult
