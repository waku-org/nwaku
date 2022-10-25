{.push raises: [Defect].}

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
  ./protocol,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec


logScope:
  topics = "wakulightpush.client"


type WakuLightPushClient* = ref object
    peerManager*: PeerManager
    rng*: ref rand.HmacDrbgContext


proc new*(T: type WakuLightPushClient, 
          peerManager: PeerManager, 
          rng: ref rand.HmacDrbgContext): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)


proc request*(wl: WakuLightPushClient, req: PushRequest, peer: RemotePeerInfo): Future[WakuLightPushResult[void]] {.async, gcsafe.} = 
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)
  let connection = connOpt.get()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: req)
  await connection.writeLP(rpc.encode().buffer)

  var message = await connection.readLp(MaxRpcSize.int)
  let decodeRespRes = PushRPC.init(message)
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


### Set lightpush peer and send push requests

proc setPeer*(wl: WakuLightPushClient, peer: RemotePeerInfo) =
  wl.peerManager.addPeer(peer, WakuLightPushCodec)
  waku_lightpush_peers.inc()

proc request*(wl: WakuLightPushClient, req: PushRequest): Future[WakuLightPushResult[void]] {.async, gcsafe.} =
  let peerOpt = wl.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_lightpush_errors.inc(labelValues = [peerNotFoundFailure])
    return err(peerNotFoundFailure)

  return await wl.request(req, peerOpt.get())
