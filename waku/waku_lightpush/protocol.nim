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
  ./protocol_metrics,
  ../common/ratelimit,
  ../common/waku_service_metrics

export ratelimit

logScope:
  topics = "waku lightpush"

type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: Option[TokenBucket]

proc extractInfoFromReq(
    self: PushRPC
): tuple[reqId: string, pubsubTopic: string, msgHash: string, message: WakuMessage] =
  ## Simply extract a tuple with the underlying data stored in `PushRPC`

  let requestId = self.requestId
  var
    pubsubTopic = ""
    msgHash = ""
    message: WakuMessage

  if not self.request.isNone():
    message = self.request.get().message
    pubSubTopic = self.request.get().pubSubTopic
    msgHash = pubsubTopic.computeMessageHash(message).to0xHex()

  return (requestId, pubsubTopic, msgHash, message)

proc handleRequest*(
    wl: WakuLightPush, peerId: PeerId, buffer: seq[byte]
): Future[PushRPC] {.async.} =
  let reqDecodeRes = PushRPC.decode(buffer)
  var
    isSuccess = false
    isRejectedDueRateLimit = false
    pushResponseInfo = ""
    requestId = ""
    pubsubTopic = ""
    msgHash = ""

  if reqDecodeRes.isErr():
    pushResponseInfo = decodeRpcFailure & ": " & $reqDecodeRes.error
    error "bad lightpush request", error = $reqDecodeRes.error
  elif reqDecodeRes.get().request.isNone():
    pushResponseInfo = emptyRequestBodyFailure
    error "lightpush request is none"
  elif wl.requestRateLimiter.isSome() and not wl.requestRateLimiter.get().tryConsume(1):
    isRejectedDueRateLimit = true
    let pushRpcRequest = reqDecodeRes.get()

    let reqInfo = pushRpcRequest.extractInfoFromReq()

    error "lightpush request rejected due rate limit exceeded",
      peer_id = peerId,
      requestId = reqInfo.reqId,
      pubsubTopic = reqInfo.pubsubTopic,
      msg_hash = reqInfo.msgHash

    pushResponseInfo = TooManyRequestsMessage
    waku_service_requests_rejected.inc(labelValues = ["Lightpush"])
  else:
    waku_service_requests.inc(labelValues = ["Lightpush"])
    waku_lightpush_messages.inc(labelValues = ["PushRequest"])

    let reqInfo = reqDecodeRes.get().extractInfoFromReq()

    requestId = reqInfo.reqId
    pubsubTopic = reqInfo.pubsubTopic
    msgHash = reqInfo.msgHash

    let handleRes = await wl.pushHandler(peerId, pubsubTopic, reqInfo.message)

    isSuccess = handleRes.isOk()
    pushResponseInfo = (if isSuccess: "OK" else: handleRes.error)

  if not isSuccess and not isRejectedDueRateLimit:
    waku_lightpush_errors.inc(labelValues = [pushResponseInfo])

    error "failed to push message",
      pubsubTopic = pubsubTopic, msg_hash = msgHash, error = pushResponseInfo

  if isSuccess:
    info "lightpush request processed correctly",
      lightpush_client_peer_id = shortLog(peerId),
      requestId = requestId,
      pubsubTopic = pubsubTopic,
      msg_hash = msgHash

  let response = PushResponse(isSuccess: isSuccess, info: some(pushResponseInfo))
  let rpc = PushRPC(requestId: requestId, response: some(response))
  return rpc

proc initProtocolHandler(wl: WakuLightPush) =
  proc handle(conn: Connection, proto: string) {.async.} =
    let buffer = await conn.readLp(DefaultMaxRpcSize)
    let rpc = await handleRequest(wl, conn.peerId, buffer)
    await conn.writeLp(rpc.encode().buffer)

  wl.handler = handle
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wl = WakuLightPush(
    rng: rng,
    peerManager: peerManager,
    pushHandler: pushHandler,
    requestRateLimiter: newTokenBucket(rateLimitSetting),
  )
  wl.initProtocolHandler()
  return wl
