when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
 ../waku_core,
 ../waku_relay,
 ./common,
 ./protocol,
 ../waku_rln_relay,
 ../waku_rln_relay/protocol_types,
 ../common/ratelimit
import
 std/times,
 libp2p/peerid,
 stew/byteutils

proc generateAndValidateRLNProof*(rlnPeer: Option[WakuRLNRelay], message: WakuMessage): (string, WakuMessage) =
  var rlnResultInfo = ""
  # TODO: check and validate if the message already has RLN proof?
  if rlnPeer.isNone():
    return (rlnResultInfo, message) # publishing message without RLN proof

  # generate and append RLN proof
  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
  var msgWithProof = message
  let appendProofRes = rlnPeer.get().appendRLNProof(msgWithProof, senderEpochTime)
  if appendProofRes.isErr():
    rlnResultInfo = "RLN proof generation failed: " & appendProofRes.error

  return (rlnResultInfo, msgWithProof)

proc getPushHandler*(
    wakuRelay: WakuRelay,
    rlnPeer: Option[WakuRLNRelay] = none[WakuRLNRelay]()
): PushMessageHandler =
  if wakuRelay.isNil():
    debug "mounting lightpush without relay (nil)"
    return proc(
      peer: PeerId, pubsubTopic: string, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      return err("no waku relay found")
  else:
    debug "mounting lightpush with relay"
    return proc(
      peer: PeerId, pubsubTopic: string, message: WakuMessage
    ): Future[WakuLightPushResult[void]] {.async.} =
      # append RLN proof
      let (rlnResultInfo, msgWithProof) = generateAndValidateRLNProof(rlnPeer, message)
      if rlnResultInfo == "":
        let validationRes = await wakuRelay.validateMessage(pubSubTopic, msgWithProof)
        if validationRes.isErr():
          return err(validationRes.error)

        let publishedCount = await wakuRelay.publish(pubsubTopic, msgWithProof)
        if publishedCount == 0:
          ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
          let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
          debug "Lightpush request has not been published to any peers", msg_hash = msgHash

        return ok()
      else:
        return err(rlnResultInfo)