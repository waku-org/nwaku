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
  ../waku_message,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics


logScope:
  topics = "waku lightpush"


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
