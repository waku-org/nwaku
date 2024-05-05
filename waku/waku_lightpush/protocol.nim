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
  # ../common/waku_service_metrics,
  # ../waku_rln_relay/rln_relay,
  # ../waku_rln_relay/protocol_types,
  # ../common/error_handling

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

#   nullifierLog*: Table[Epoch, Table[seq[byte], bool]]
#   lastEpoch*: Epoch
#   epochSizeSec*: uint64
#   rlnMaxEpochGap*: uint64

#   MessageValidationResult* = enum
#     Valid
#     Invalid
#     Spam

#   Epoch = uint64

#   ProofMetadata = object
#     nullifier: seq[byte]

# proc calcEpoch(wl: WakuLightPush, t: float64): Epoch =
#   let e = uint64(t / wl.epochSizeSec.float64)
#   return e

# proc getCurrentEpoch(wl: WakuLightPush): Epoch =
#   wl.calcEpoch(epochTime())

# proc hasDuplicate(wl: WakuLightPush, epoch: Epoch, proofMetadata: ProofMetadata): bool =
#   if not wl.nullifierLog.hasKey(epoch):
#     return false
#   if wl.nullifierLog[epoch].hasKey(proofMetadata.nullifier):
#     return true
#   return false

# type WakuRlnConfig* = object
#   rlnRelayDynamic*: bool
#   rlnRelayCredIndex*: Option[uint]
#   rlnRelayEthContractAddress*: string
#   rlnRelayEthClientAddress*: string
#   rlnRelayCredPath*: string
#   rlnRelayCredPassword*: string
#   rlnRelayTreePath*: string
#   rlnEpochSizeSec*: uint64
#   onFatalErrorAction*: OnFatalErrorHandler
#   when defined(rln_v2):
#     rlnRelayUserMessageLimit*: uint64

# proc validateMessage*(
#     wl: WakuLightPush, msg: WakuMessage, timeOption = none(float64)
# ): MessageValidationResult =

  # let wakuRlnRelay = (await WakuRlnRelay.new(wakuRlnConfig)).valueOr:
  #   raiseAssert $error
  # let validationRes = WakuRlnRelay.validateMessage(msg, timeOption)
  # return validationRes

  ## validate the supplied `msg` based on the waku-rln-relay routing protocol i.e.,
  ## the `msg`'s epoch is within MaxEpochGap of the current epoch
  ## the `msg` has valid rate limit proof
  ## the `msg` does not violate the rate limit
  ## `timeOption` indicates Unix epoch time (fractional part holds sub-seconds)
  ## if `timeOption` is supplied, then the current epoch is calculated based on that

  # let decodeRes = RateLimitProof.init(msg.proof)
  # if decodeRes.isErr():
  #   return MessageValidationResult.Invalid

  # let proof = decodeRes.get()

  # # checks if the `msg`'s epoch is far from the current epoch
  # # it corresponds to the validation of rln external nullifier
  # var epoch: Epoch
  # if timeOption.isSome():
  #   epoch = wl.calcEpoch(timeOption.get())
  # else:
  #   # get current rln epoch
  #   epoch = wl.getCurrentEpoch()

  # let
  #   msgEpoch = proof.epoch
  #   # calculate the gaps
  #   gap = absDiff(epoch, msgEpoch)

  # trace "epoch info", currentEpoch = fromEpoch(epoch), msgEpoch = fromEpoch(msgEpoch)

  # # validate the epoch
  # if gap > wl.rlnMaxEpochGap:
  #   # message's epoch is too old or too ahead
  #   # accept messages whose epoch is within +-MaxEpochGap from the current epoch
  #   warn "invalid message: epoch gap exceeds a threshold",
  #     gap = gap, payloadLen = msg.payload.len, msgEpoch = fromEpoch(proof.epoch)
  #   waku_rln_invalid_messages_total.inc(labelValues = ["invalid_epoch"])
  #   return MessageValidationResult.Invalid

  # let rootValidationRes = rlnPeer.groupManager.validateRoot(proof.merkleRoot)
  # if not rootValidationRes:
  #   warn "invalid message: provided root does not belong to acceptable window of roots",
  #     provided = proof.merkleRoot.inHex(),
  #     validRoots = rlnPeer.groupManager.validRoots.mapIt(it.inHex())
  #   waku_rln_invalid_messages_total.inc(labelValues = ["invalid_root"])
  #   return MessageValidationResult.Invalid

  # # verify the proof
  # let
  #   contentTopicBytes = msg.contentTopic.toBytes
  #   input = concat(msg.payload, contentTopicBytes)

  # waku_rln_proof_verification_total.inc()
  # waku_rln_proof_verification_duration_seconds.nanosecondTime:
  #   let proofVerificationRes = rlnPeer.groupManager.verifyProof(input, proof)

  # if proofVerificationRes.isErr():
  #   waku_rln_errors_total.inc(labelValues = ["proof_verification"])
  #   warn "invalid message: proof verification failed", payloadLen = msg.payload.len
  #   return MessageValidationResult.Invalid
  # if not proofVerificationRes.value():
  #   # invalid proof
  #   warn "invalid message: invalid proof", payloadLen = msg.payload.len
  #   waku_rln_invalid_messages_total.inc(labelValues = ["invalid_proof"])
  #   return MessageValidationResult.Invalid

  # check if double messaging has happened
  # let proofMetadataRes = proof.extractMetadata()
  # if proofMetadataRes.isErr():
  #   waku_rln_errors_total.inc(labelValues = ["proof_metadata_extraction"])
  #   return MessageValidationResult.Invalid
  # let hasDup = wl.hasDuplicate(msgEpoch, proofMetadataRes.get())
  # if hasDup.isErr():
  #   waku_rln_errors_total.inc(labelValues = ["duplicate_check"])
  # elif hasDup.value == true:
  #   trace "invalid message: message is spam", payloadLen = msg.payload.len
  #   waku_rln_spam_messages_total.inc()
  #   return MessageValidationResult.Spam

  # trace "message is valid", payloadLen = msg.payload.len
  # let rootIndex = rlnPeer.groupManager.indexOfRoot(proof.merkleRoot)
  # waku_rln_valid_messages_total.observe(rootIndex.toFloat())
  # return MessageValidationResult.Valid

# proc validateMessageAndUpdateLog*(
#     rlnPeer: WakuRLNRelay, msg: WakuMessage, timeOption = none(float64)
# ): MessageValidationResult =
#   ## validates the message and updates the log to prevent double messaging
#   ## in future messages

#   let result = rlnPeer.validateMessage(msg, timeOption)

#   let decodeRes = RateLimitProof.init(msg.proof)
#   if decodeRes.isErr():
#     return MessageValidationResult.Invalid

#   let msgProof = decodeRes.get()
#   let proofMetadataRes = msgProof.extractMetadata()

#   if proofMetadataRes.isErr():
#     return MessageValidationResult.Invalid

#   # insert the message to the log (never errors)
#   discard rlnPeer.updateLog(msgProof.epoch, proofMetadataRes.get())

#   return result

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
    let validateMessageRes = wl.validateMessage(pubSubTopic,message)

    # validate msg before relay
    if validateMessageRes.isErr():
      pushResponseInfo = messageValidationFailure & ": " & $validateMessageRes.error
    elif wl.requestRateLimiter.isSome() and not wl.requestRateLimiter.get().tryConsume(1):
      isRejectedDueRateLimit = true
      debug "lightpush request rejected due rate limit exceeded",
        peerId = peerId, requestId = requestId
      pushResponseInfo = TooManyRequestsMessage
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
