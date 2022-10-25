{.push raises: [Defect].}

import
  std/options,
  stew/results,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../waku_message,
  ../waku_relay,
  ../../node/peer_manager/peer_manager,
  ../../utils/requests,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics


logScope:
  topics = "wakulightpush"


const WakuLightPushCodec* = "/vac/waku/lightpush/2.0.0-beta1"


type
  WakuLightPushResult*[T] = Result[T, string]
  
  PushMessageHandler* = proc(peer: PeerId, pubsubTopic: string, message: WakuMessage): Future[WakuLightPushResult[void]] {.gcsafe, closure.}

  WakuLightPush* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    pushHandler*: PushMessageHandler

proc initProtocolHandler*(wl: WakuLightPush) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let buffer = await conn.readLp(MaxRpcSize.int)
    let reqDecodeRes = PushRPC.init(buffer)
    if reqDecodeRes.isErr():
      error "failed to decode rpc"
      waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
      return

    let req = reqDecodeRes.get()
    if req.request == PushRequest():
      error "invalid lightpush rpc received", error=emptyRequestBodyFailure
      waku_lightpush_errors.inc(labelValues = [emptyRequestBodyFailure])
      return

    waku_lightpush_messages.inc(labelValues = ["PushRequest"])
    let
      pubSubTopic = req.request.pubSubTopic
      message = req.request.message
    debug "push request", peerId=conn.peerId, requestId=req.requestId, pubsubTopic=pubsubTopic

    var response: PushResponse
    let handleRes = await wl.pushHandler(conn.peerId, pubsubTopic, message)
    if handleRes.isOk():
      response = PushResponse(is_success: true, info: "OK")
    else:
      response = PushResponse(is_success: false, info: handleRes.error)
      waku_lightpush_errors.inc(labelValues = [messagePushFailure])
      error "pushed message handling failed", error=handleRes.error

    let rpc = PushRPC(requestId: req.requestId, response: response)
    await conn.writeLp(rpc.encode().buffer)

  wl.handler = handle
  wl.codec = WakuLightPushCodec

proc new*(T: type WakuLightPush, 
          peerManager: PeerManager, 
          rng: ref rand.HmacDrbgContext,
          pushHandler: PushMessageHandler): T = 
  let wl = WakuLightPush(rng: rng, peerManager: peerManager, pushHandler: pushHandler)
  wl.initProtocolHandler()
  return wl


proc setPeer*(wlp: WakuLightPush, peer: RemotePeerInfo) {.
  deprecated: "Use 'WakuLightPushClient.setPeer()' instead" .} = 
  wlp.peerManager.addPeer(peer, WakuLightPushCodec)
  waku_lightpush_peers.inc()

proc request(wl: WakuLightPush, req: PushRequest, peer: RemotePeerInfo): Future[WakuLightPushResult[PushResponse]] {.async, gcsafe,
  deprecated: "Use 'WakuLightPushClient.request()' instead" .} = 
  let connOpt = await wl.peerManager.dialPeer(peer, WakuLightPushCodec)
  if connOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)

  let connection = connOpt.get()

  let rpc = PushRPC(requestId: generateRequestId(wl.rng), request: req)
  await connection.writeLP(rpc.encode().buffer)

  var message = await connection.readLp(MaxRpcSize.int)
  let res = PushRPC.init(message)

  if res.isErr():
    waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
    return err(decodeRpcFailure)

  let rpcRes = res.get()
  if rpcRes.response == PushResponse():
    return err("empty response body")

  return ok(rpcRes.response)

proc request*(wl: WakuLightPush, req: PushRequest): Future[WakuLightPushResult[PushResponse]] {.async, gcsafe,
  deprecated: "Use 'WakuLightPushClient.request()' instead" .} = 
  let peerOpt = wl.peerManager.selectPeer(WakuLightPushCodec)
  if peerOpt.isNone():
    waku_lightpush_errors.inc(labelValues = [dialFailure])
    return err(dialFailure)

  return await wl.request(req, peerOpt.get())
