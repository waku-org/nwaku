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

proc generateAndValidateRLNProof*(rlnPeer: Option[WakuRLNRelay], message: WakuMessage): Result[WakuMessage, string] =
  # TODO: check and validate if the message already has RLN proof?
  if rlnPeer.isNone():
    return ok(message) # publishing message without RLN proof

  # generate and append RLN proof
  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
  var msgWithProof = message
  let appendProofRes = rlnPeer.get().appendRLNProof(msgWithProof, senderEpochTime)
  if appendProofRes.isOk():
    return ok(msgWithProof)
  
  return err("RLN proof generation failed: " & appendProofRes.error)

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
    peer: PeerId, pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    return err("no waku relay found")

proc getRelayPushHandler*(
  wakuRelay: WakuRelay,
  rlnPeer: Option[WakuRLNRelay] = none[WakuRLNRelay]()
): PushMessageHandler =
  return proc(
    peer: PeerId, pubsubTopic: string, message: WakuMessage
  ): Future[WakuLightPushResult[void]] {.async.} =
    # append RLN proof
    let msgWithProof = generateAndValidateRLNProof(rlnPeer, message)
    if msgWithProof.isErr():
      return err(msgWithProof.error)

    let validationRes = await wakuRelay.validateMessage(pubSubTopic, msgWithProof.value)
    if validationRes.isErr():
      return err(validationRes.error)

    let publishedCount = await wakuRelay.publish(pubsubTopic, msgWithProof.value)
    if publishedCount == 0:
      ## Agreed change expected to the lightpush protocol to better handle such case. https://github.com/waku-org/pm/issues/93
      let msgHash = computeMessageHash(pubsubTopic, message).to0xHex()
      debug "Lightpush request has not been published to any peers", msg_hash = msgHash

    return ok()