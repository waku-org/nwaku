{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid, libp2p/stream/connection
import
  ../waku_core/peers,
  ../node/peer_manager,
  ../node/delivery_monitor/publish_observer,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  publishObservers: seq[PublishObserver]

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

proc addPublishObserver*(wl: WakuLightPushClient, obs: PublishObserver) =
  wl.publishObservers.add(obs)

proc ensureTimestampSet(message: var WakuMessage) =
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

## Short log string for peer identifiers (overloads for convenience)
func shortPeerId(peer: PeerId): string =
  shortLog(peer)

func shortPeerId(peer: RemotePeerInfo): string =
  shortLog(peer.peerId)

proc sendPushRequest(
    wl: WakuLightPushClient,
    req: LightPushRequest,
    peer: PeerId | RemotePeerInfo,
    conn: Option[Connection] = none(Connection),
): Future[WakuLightPushResult] {.async.} =
  let connection = conn.valueOr:
    (await wl.peerManager.dialPeer(peer, WakuLightPushCodec)).valueOr:
      waku_lightpush_v3_errors.inc(labelValues = [dialFailure])
      return lighpushErrorResult(
        LightPushErrorCode.NO_PEERS_TO_RELAY,
        dialFailure & ": " & $peer & " is not accessible",
      )

  try:
    await connection.writeLp(req.encode().buffer)
  except LPStreamRemoteClosedError:
    error "Failed to write request to peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to write request to peer: " & getCurrentExceptionMsg()
    )

  var buffer: seq[byte]
  try:
    buffer = await connection.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    error "Failed to read response from peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to read response from peer: " & getCurrentExceptionMsg()
    )

  let response = LightpushResponse.decode(buffer).valueOr:
    error "failed to decode response"
    waku_lightpush_v3_errors.inc(labelValues = [decodeRpcFailure])
    return lightpushResultInternalError(decodeRpcFailure)

  let requestIdMismatch = response.requestId != req.requestId
  let tooManyRequests = response.statusCode == LightPushErrorCode.TOO_MANY_REQUESTS
  if requestIdMismatch and (not tooManyRequests):
    # response with TOO_MANY_REQUESTS error code has no requestId by design
    error "response failure, requestId mismatch",
      requestId = req.requestId, responseRequestId = response.requestId
    return lightpushResultInternalError("response failure, requestId mismatch")

  return toPushResult(response)

proc publish*(
    wl: WakuLightPushClient,
    pubsubTopic: Option[PubsubTopic] = none(PubsubTopic),
    wakuMessage: WakuMessage,
    peer: PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  var message = wakuMessage
  ensureTimestampSet(message)

  let msgHash = computeMessageHash(pubsubTopic.get(""), message).to0xHex
  info "publish", peerId = shortPeerId(peer), msg_hash = msgHash

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubsubTopic: pubsubTopic, message: message
  )
  let relayPeerCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubsubTopic.get(""), message)

  return lightpushSuccessResult(relayPeerCount)

proc publishToAny*(
    wl: WakuLightPushClient, pubsubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[WakuLightPushResult] {.async, gcsafe.} =
  # Like publish, but selects a peer automatically from the peer manager

  var message = wakuMessage
  ensureTimestampSet(message)

  let msgHash = computeMessageHash(pubsubTopic, message).to0xHex
  info "publishToAny", msg_hash = msgHash

  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    # TODO: check if it is matches the situation - shall we distinguish client side missing peers from server side?
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
    )

  info "publishToAny",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = peer.peerId,
    msg_hash = computeMessageHash(pubsubTopic, message).to0xHex,
    sentTime = getNowInNanosecondTime()

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng),
    pubSubTopic: some(pubSubTopic),
    message: message,
  )
  let publishedCount = ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return lightpushSuccessResult(publishedCount)

proc publishWithConn*(
    wl: WakuLightPushClient,
    pubSubTopic: PubsubTopic,
    message: WakuMessage,
    conn: Connection,
    destPeer: PeerId,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  info "publishWithConn",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = destPeer,
    msg_hash = computeMessageHash(pubsubTopic, message).to0xHex,
    sentTime = getNowInNanosecondTime()

  let pushRequest = LightpushRequest(
    requestId: generateRequestId(wl.rng),
    pubSubTopic: some(pubSubTopic),
    message: message,
  )
  #TODO: figure out how to not pass destPeer as this is just a hack
  let publishedCount =
    ?await wl.sendPushRequest(pushRequest, destPeer, conn = some(conn))

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return lightpushSuccessResult(publishedCount)
