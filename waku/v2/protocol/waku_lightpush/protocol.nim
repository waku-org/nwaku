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
  ../../node/peer_manager,
  ../waku_message,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics


logScope:
  topics = "waku lightpush"


const WakuLightPushCodec* = "/vac/waku/lightpush/2.0.0-beta1"


type
  WakuLightPushResult*[T] = Result[T, string]

  PushMessageHandler* = proc(peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage): Future[WakuLightPushResult[void]] {.gcsafe, closure.}

  WakuLightPush* = ref object of LPProtocol
    rng*: ref rand.HmacDrbgContext
    peerManager*: PeerManager
    pushHandler*: PushMessageHandler

proc initProtocolHandler*(wl: WakuLightPush) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let buffer = await conn.readLp(MaxRpcSize.int)
    let reqDecodeRes = PushRPC.decode(buffer)
    if reqDecodeRes.isErr():
      error "failed to decode rpc"
      waku_lightpush_errors.inc(labelValues = [decodeRpcFailure])
      return

    let req = reqDecodeRes.get()
    if req.request.isNone():
      error "invalid lightpush rpc received", error=emptyRequestBodyFailure
      waku_lightpush_errors.inc(labelValues = [emptyRequestBodyFailure])
      return

    waku_lightpush_messages.inc(labelValues = ["PushRequest"])
    let
      pubSubTopic = req.request.get().pubSubTopic
      message = req.request.get().message
    debug "push request", peerId=conn.peerId, requestId=req.requestId, pubsubTopic=pubsubTopic

    var response: PushResponse
    var handleRes: WakuLightPushResult[void]
    try:
      handleRes = await wl.pushHandler(conn.peerId, pubsubTopic, message)
    except Exception:
      response = PushResponse(is_success: false, info: some(getCurrentExceptionMsg()))
      waku_lightpush_errors.inc(labelValues = [messagePushFailure])
      error "pushed message handling failed", error= getCurrentExceptionMsg()


    if handleRes.isOk():
      response = PushResponse(is_success: true, info: some("OK"))
    else:
      response = PushResponse(is_success: false, info: some(handleRes.error))
      waku_lightpush_errors.inc(labelValues = [messagePushFailure])
      error "pushed message handling failed", error=handleRes.error

    let rpc = PushRPC(requestId: req.requestId, response: some(response))
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
