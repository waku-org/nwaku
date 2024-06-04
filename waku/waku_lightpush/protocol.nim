when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options, std/times, stew/results, stew/byteutils, chronicles, chronos, metrics, bearssl/rand
import
  ../node/peer_manager/peer_manager,
  ../waku_core,
  ./common,
  ./rpc,
  ./rpc_codec,
  ./protocol_metrics,
  ../common/ratelimit,
  ../common/waku_service_metrics,
  ../waku_rln_relay/rln_relay, ../waku_rln_relay/protocol_types
export ratelimit

logScope:
  topics = "waku lightpush"

type WakuLightPush* = ref object of LPProtocol
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  pushHandler*: PushMessageHandler
  requestRateLimiter*: Option[TokenBucket]
  rlnPeer*: Option[WakuRLNRelay]

proc generateAndValidateRLNProof*(wl: WakuLightPush, message: var WakuMessage): (string, WakuMessage) =
  var pushResponseInfo = ""
  # TODO: check and validate if the message already has RLN proof?
  if wl.rlnPeer.isNone():
    return (pushResponseInfo, message) # publishing message without RLN proof

  # generate and append RLN proof
  let 
    rlnPeer = wl.rlnPeer.get()
    time = getTime().toUnix()
    senderEpochTime = float64(time)
  let appendProofRes = rlnPeer.appendRLNProof(message, senderEpochTime)
  if appendProofRes.isErr():
    pushResponseInfo = "RLN proof generation failed: " & appendProofRes.error
  
  # validate RLN proof
  let validateProofRes = rlnPeer.validateMessage(message, some(senderEpochTime))
  if validateProofRes != MessageValidationResult.Valid:
    pushResponseInfo = "RLN proof validation failed"
  return (pushResponseInfo, message)

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
    var message = request.get().message
    waku_lightpush_messages.inc(labelValues = ["PushRequest"])
    debug "push request",
      peerId = peerId,
      requestId = requestId,
      pubsubTopic = pubsubTopic,
      hash = pubsubTopic.computeMessageHash(message).to0xHex()

    let (rlnResultInfo, msgWithProof) = generateAndValidateRLNProof(wl, message)
    pushResponseInfo = rlnResultInfo
    if pushResponseInfo == "":
      let handleRes = await wl.pushHandler(peerId, pubSubTopic, msgWithProof)
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
    var rpc: PushRPC
    wl.requestRateLimiter.checkUsageLimit(WakuLightPushCodec, conn):
      let buffer = await conn.readLp(DefaultMaxRpcSize)

      waku_service_inbound_network_bytes.inc(
        amount = buffer.len().int64, labelValues = [WakuLightPushCodec]
      )

      rpc = await handleRequest(wl, conn.peerId, buffer)
    do:
      debug "lightpush request rejected due rate limit exceeded",
        peerId = conn.peerId, limit = $wl.requestRateLimiter

      rpc = static(
        PushRPC(
          ## We will not copy and decode RPC buffer from stream only for requestId
          ## in reject case as it is comparably too expensive and opens possible
          ## attack surface
          requestId: "N/A",
          response:
            some(PushResponse(isSuccess: false, info: some(TooManyRequestsMessage))),
        )
      )

    await conn.writeLp(rpc.encode().buffer)

    ## For lightpush might not worth to measure outgoing trafic as it is only
    ## small respones about success/failure

  wl.handler = handle
  wl.codec = WakuLightPushCodec

proc new*(
    T: type WakuLightPush,
    peerManager: PeerManager,
    rng: ref rand.HmacDrbgContext,
    pushHandler: PushMessageHandler,
    rlnPeer: Option[WakuRLNRelay] = none[WakuRLNRelay](),
    rateLimitSetting: Option[RateLimitSetting] = none[RateLimitSetting](),
): T =
  let wl = WakuLightPush(
    rng: rng,
    peerManager: peerManager,
    pushHandler: pushHandler,
    requestRateLimiter: newTokenBucket(rateLimitSetting),
    rlnPeer: rlnPeer,
  )
  wl.initProtocolHandler()
  return wl
