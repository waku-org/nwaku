when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../../node/peer_manager/peer_manager,
  ../../utils/requests,
  ../waku_message,
  ./protocol,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec


logScope:
  topics = "waku lightpush client"


type WakuLightPushClient* = ref object
    peerManager*: PeerManager
    rng*: ref rand.HmacDrbgContext


proc new*(T: type WakuLightPushClient, 
          peerManager: PeerManager, 
          rng: ref rand.HmacDrbgContext): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)


proc sendPushRequest(wl: WakuLightPushClient, req: PushRequest, peer: PeerId|RemotePeerInfo): Future[WakuLightPushResult[void]] {.async, gcsafe.} = 
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)
  let connection = connOpt.get()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: req)
  await connection.writeLP(rpc.encode().buffer)

  var buffer = await connection.readLp(MaxRpcSize.int)
  let decodeRespRes = PushRPC.init(buffer)
  if decodeRespRes.isErr():
    error "failed to decode response"
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return err(decodeRpcFailure)

  let pushResponseRes = decodeRespRes.get()
  if pushResponseRes.response == PushResponse():
    waku_lightpush_errors.inc(labelValues = [emptyResponseBodyFailure])
    return err(emptyResponseBodyFailure)

  let response = pushResponseRes.response
  if not response.isSuccess:
    if response.info != "":
      return err(response.info)
    else:
      return err("unknown failure")

  return ok()

proc publish*(wl: WakuLightPushClient, pubsubTopic: string, message: WakuMessage, peer: PeerId|RemotePeerInfo): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  let pushRequest = PushRequest(pubsubTopic: pubsubTopic, message: message)
  return await wl.sendPushRequest(pushRequest, peer)
