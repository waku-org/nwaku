when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options, stew/results, stew/byteutils, chronicles, chronos, metrics, bearssl/rand
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics

logScope:
  topics = "waku lightpush"

type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler

proc handleRequest*(
    wl: WakuLightPush, peerId: PeerId, buffer: seq[byte]
): Future[PushRPC] {.async.} =
  let reqDecodeRes = PushRPC.decode(buffer)
  var
    isSuccess = false
    pushResponseInfo = ""
    requestId = ""

  if reqDecodeRes.isErr():
    pushResponseInfo = decodeRpcFailure & ": " & $reqDecodeRes.error
  elif reqDecodeRes.get().request.isNone():
    pushResponseInfo = emptyRequestBodyFailure
  else:
    let pushRpcRequest = reqDecodeRes.get()

    requestId = pushRpcRequest.requestId

    let
      request = pushRpcRequest.request

      pubSubTopic = request.get().pubSubTopic
      message = request.get().message
    waku_lightpush_messages.inc(labelValues = ["PushRequest"])
    debug "push request",
      peerId = peerId,
      requestId = requestId,
      pubsubTopic = pubsubTopic,
      hash = pubsubTopic.computeMessageHash(message).to0xHex()

    let handleRes = await wl.pushHandler(peerId, pubsubTopic, message)
    isSuccess = handleRes.isOk()
    pushResponseInfo = (if isSuccess: "OK" else: handleRes.error)

  if not isSuccess:
    waku_lightpush_errors.inc(labelValues = [pushResponseInfo])
    error "failed to push message", error = pushResponseInfo
  let response = PushResponse(isSuccess: isSuccess, info: some(pushResponseInfo))
  let rpc = PushRPC(requestId: requestId, response: some(response))
  return rpc

proc initProtocolHandler(wl: WakuLightPush) =
  proc handle(conn: Connection, proto: string) {.async.} =
    let buffer = await conn.readLp(MaxRpcSize.int)
    let rpc = await handleRequest(wl, conn.peerId, buffer)
    await conn.writeLp(rpc.encode().buffer)

  wl.handler = handle
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
): T =
  let wl = WakuLightPush(rng: rng, peerManager: peerManager, pushHandler: pushHandler)
  wl.initProtocolHandler()
  return wl
