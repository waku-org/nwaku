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
  ./rpc_codec

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  peerManager*: PeerManager
  rng*: ref rand.HmacDrbgContext
  publishObservers: seq[PublishObserver]

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

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

  return ok()

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: PubsubTopic,
    message: WakuMessage,
    peer: PeerId | RemotePeerInfo,
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  when peer is PeerId:
    info "publish",
      peerId = shortLog(peer),
      msg_hash = computeMessageHash(pubsubTopic, message).to0xHex
  else:
    info "publish",
      peerId = shortLog(peer.peerId),
      msg_hash = computeMessageHash(pubsubTopic, message).to0xHex

  let pushRequest = PushRequest(pubSubTopic: pubSubTopic, message: message)
  ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return ok()

proc publishToAny*(
    wl: WakuLightPushClient, pubSubTopic: PubsubTopic, message: WakuMessage
): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  ## This proc is similar to the publish one but in this case
  ## we don't specify a particular peer and instead we get it from peer manager

  info "publishToAny", msg_hash = computeMessageHash(pubsubTopic, message).to0xHex

  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    return err("could not retrieve a peer supporting WakuLightPushCodec")

  let pushRequest = PushRequest(pubSubTopic: pubSubTopic, message: message)
  ?await wl.sendPushRequest(pushRequest, peer)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic, message)

  return ok()
