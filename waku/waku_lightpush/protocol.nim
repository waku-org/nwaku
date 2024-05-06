when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options, stew/results, stew/byteutils, chronicles, chronos, metrics, bearssl/rand, std/strformat
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

proc validateMessage*(
    wl: WakuLightPush, pubsubTopic: string, msg: WakuMessage
): Future[Result[void, string]] {.async.} =
  let messageSizeBytes = msg.encode().buffer.len
  let msgHash = computeMessageHash(pubsubTopic, msg).to0xHex()
  let maxMessageSize = int(DefaultMaxWakuMessageSize)

  if messageSizeBytes > maxMessageSize:
    let message = fmt"Message size exceeded maximum of {maxMessageSize} bytes"
    error "too large Waku message",
      msg_hash = msgHash,
      error = message,
      messageSizeBytes = messageSizeBytes,
      maxMessageSize = maxMessageSize

    return err(message)

  return ok()

proc handleRequest*(
    wl: WakuLightPush, peerId: PeerId, buffer: seq[byte]
): Future[PushRPC] {.async.} =
  let reqDecodeRes = PushRPC.decode(buffer)
  var
    isSuccess = false
    isRejectedDueRateLimit = false
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
    let validateMessageRes = await wl.validateMessage(pubSubTopic, message)

    # validate msg before relay
    if validateMessageRes.isErr():
      pushResponseInfo = messageValidationFailure & ": " &
          $validateMessageRes.error
      waku_service_requests_rejected.inc(labelValues = ["Lightpush"])
    elif wl.requestRateLimiter.isSome() and not wl.requestRateLimiter.get().tryConsume(1):
      isRejectedDueRateLimit = true
      debug "lightpush request rejected due rate limit exceeded",
        peerId = peerId, requestId = requestId
      pushResponseInfo = TooManyRequestsMessage
      waku_service_requests_rejected.inc(labelValues = ["Lightpush"])
    else:
      waku_service_requests.inc(labelValues = ["Lightpush"])

      waku_lightpush_messages.inc(labelValues = ["PushRequest"])
      debug "push request",
        peerId = peerId,
        requestId = requestId,
        pubsubTopic = pubsubTopic,
        hash = pubsubTopic.computeMessageHash(message).to0xHex()

      let handleRes = await wl.pushHandler(peerId, pubsubTopic, message)
      isSuccess = handleRes.isOk()
      pushResponseInfo = (if isSuccess: "OK" else: handleRes.error)

  if not isSuccess and not isRejectedDueRateLimit:
    waku_lightpush_errors.inc(labelValues = [pushResponseInfo])
    error "failed to push message", error = pushResponseInfo
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
