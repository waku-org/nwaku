{.push raises: [].}

import
  std/[options, strutils],
  results,
  stew/byteutils,
  chronicles,
  chronos,
  metrics,
  bearssl/rand
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ../waku_core/topics/sharding,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/rate_limit/request_limiter

logScope:
  topics = "waku lightpush"

type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: RequestRateLimiter
  sharding: Sharding

proc handleRequest(
    wl: WakuLightPush, peerId: PeerId, pushRequest: LightPushRequest
): Future[WakuLightPushResult] {.async.} =
  let pubsubTopic = pushRequest.pubSubTopic.valueOr:
    let parsedTopic = NsContentTopic.parse(pushRequest.message.contentTopic).valueOr:
      let msg = "Invalid content-topic:" & $error
      error "lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushStatusCode.INVALID_MESSAGE_ERROR, desc: some(msg))
      )

    wl.sharding.getShard(parsedTopic).valueOr:
      let msg = "Sharding error: " & error
      error "lightpush request handling error", error = msg
      return WakuLightPushResult.err(
        (code: LightPushStatusCode.INTERNAL_SERVER_ERROR, desc: some(msg))
      )

  # ensure checking topic will not cause error at gossipsub level
  if pubsubTopic.isEmptyOrWhitespace():
    let msg = "topic must not be empty"
    error "lightpush request handling error", error = msg
    return
      WakuLightPushResult.err((code: LightPushStatusCode.BAD_REQUEST, desc: some(msg)))

  waku_lightpush_v3_messages.inc(labelValues = ["PushRequest"])

  let msg_hash = pubsubTopic.computeMessageHash(pushRequest.message).to0xHex()
  notice "handling lightpush request",
    my_peer_id = wl.peerManager.switch.peerInfo.peerId,
    peer_id = peerId,
    requestId = pushRequest.requestId,
    pubsubTopic = pushRequest.pubsubTopic,
    msg_hash = msg_hash,
    receivedTime = getNowInNanosecondTime()

  let handleRes = await wl.pushHandler(peerId, pubsubTopic, pushRequest.message)

  if handleRes.isOk():
    return ok(handleRes.get())

  return err((code: handleRes.error.code, desc: handleRes.error.desc))

proc handleRequest*(
    wl: WakuLightPush, peerId: PeerId, buffer: seq[byte]
): Future[LightPushResponse] {.async.} =
  var pushResponse: LightPushResponse

  let pushRequest = LightPushRequest.decode(buffer).valueOr:
    let desc = decodeRpcFailure & ": " & $error
    waku_lightpush_v3_errors.inc(labelValues = [desc])
    error "failed to push message", error = pushResponse.statusDesc
    return LightPushResponse(
      requestId: "N/A", # due to decode failure we don't know requestId
      statusCode: LightPushStatusCode.BAD_REQUEST.uint32,
      statusDesc: some(desc),
    )

  let res = await handleRequest(wl, peerId, pushRequest)

  let relayPeerCount = res.valueOr:
    let desc = error.desc
    waku_lightpush_v3_errors.inc(labelValues = [desc.valueOr("unknown")])
    error "failed to push message", error = pushResponse.statusDesc
    return LightPushResponse(
      requestId: pushRequest.requestId, statusCode: error.code.uint32, statusDesc: desc
    )

  return LightPushResponse(
    requestId: pushRequest.requestId,
    statusCode: LightPushStatusCode.SUCCESS.uint32,
    statusDesc: none[string](),
    relayPeerCount: some(relayPeerCount),
  )

proc initProtocolHandler(wl: WakuLightPush) =
  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var rpc: LightPushResponse
    wl.requestRateLimiter.checkUsageLimit(WakuLightPushCodec, conn):
      var buffer: seq[byte]
      try:
        buffer = await conn.readLp(DefaultMaxRpcSize)
      except LPStreamError:
        error "lightpush read stream failed", error = getCurrentExceptionMsg()
        return

      waku_service_network_bytes.inc(
        amount = buffer.len().int64, labelValues = [WakuLightPushCodec, "in"]
      )

      try:
        rpc = await handleRequest(wl, conn.peerId, buffer)
      except CatchableError:
        error "lightpush failed handleRequest", error = getCurrentExceptionMsg()
    do:
      debug "lightpush request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $wl.requestRateLimiter.setting

      rpc = static(
        LightPushResponse(
          ## We will not copy and decode RPC buffer from stream only for requestId
          ## in reject case as it is comparably too expensive and opens possible
          ## attack surface
          requestId: "N/A",
          statusCode: LightpushStatusCode.TOO_MANY_REQUESTS.uint32,
          statusDesc: some(TooManyRequestsMessage),
        )
      )

    try:
      await conn.writeLp(rpc.encode().buffer)
    except LPStreamError:
      error "lightpush write stream failed", error = getCurrentExceptionMsg()

    ## For lightpush might not worth to measure outgoing tragfic as it is only
    ## small response about success/failure

  wl.handler = handler
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
    sharding: Sharding,
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wl = WakuLightPush(
    rng: rng,
    peerManager: peerManager,
    pushHandler: pushHandler,
    requestRateLimiter: newRequestRateLimiter(rateLimitSetting),
    sharding: sharding,
  )
  wl.initProtocolHandler()
  setServiceLimitMetric(WakuLightpushCodec, rateLimitSetting)
  return wl
