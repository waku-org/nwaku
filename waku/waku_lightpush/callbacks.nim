{.push raises: [].}

import results, std/[times, options, strutils]

import
  ../waku_core,
  ../waku_core/topics/sharding,
  ../waku_relay,
  ./common,
  ../waku_rln_relay,
  ../waku_rln_relay/protocol_types

import libp2p/peerid, stew/byteutils

proc extractPubsubTopic(
    pubsubTopic: Option[PubsubTopic],
    message: WakuMessage,
    autoSharding: Option[Sharding],
): Result[PubsubTopic, ErrorStatus] =
  ## A pubsubTopic uniquely identifies a shard. Two sharding modes:
  ##   Static sharding: pubsubTopic must be specified in the request
  ##   Auto-sharding: generate pubsubTopic from message contentTopic
  proc mkErr(code: LightPushStatusCode, err: string): Result[PubsubTopic, ErrorStatus] =
    err((code, some(err)))

  let topic = pubsubTopic.valueOr:
    if autoSharding.isNone():
      return mkErr(
        LightPushErrorCode.INVALID_MESSAGE,
        "Pubsub topic is required for static sharding",
      )

    let contentTopic = NsContentTopic.parse(message.contentTopic).valueOr:
      return mkErr(LightPushErrorCode.INVALID_MESSAGE, "Invalid content topic: " & $error)

    autoSharding.get().getShard(contentTopic).valueOr:
      return
        mkErr(LightPushErrorCode.INTERNAL_SERVER_ERROR, "Auto-sharding error: " & error)

  if topic.isEmptyOrWhitespace():
    return mkErr(LightPushErrorCode.BAD_REQUEST, "Pubsub topic must not be empty or whitespace")

  return ok(topic)

proc checkAndGenerateRLNProof*(
    rlnPeer: Option[WakuRLNRelay], message: WakuMessage
): Result[WakuMessage, string] =
  # check if the message already has RLN proof
  if message.proof.len > 0:
    return ok(message)

  if rlnPeer.isNone():
    notice "Publishing message without RLN proof"
    return ok(message)
  # generate and append RLN proof
  let
    time = getTime().toUnix()
    senderEpochTime = float64(time)
  var msgWithProof = message
  rlnPeer.get().appendRLNProof(msgWithProof, senderEpochTime).isOkOr:
    return err(error)
  return ok(msgWithProof)

proc getNilPushHandler*(): PushMessageHandler =
  return proc(
      peer: PeerId,
      pubsubTopic: Option[PubsubTopic],
      message: WakuMessage,
      autoSharding: Option[Sharding],
  ): Future[WakuLightPushResult] {.async.} =
    return lightpushResultInternalError("no waku relay found")

proc getRelayPushHandler*(
    wakuRelay: WakuRelay, rlnPeer: Option[WakuRLNRelay] = none[WakuRLNRelay]()
): PushMessageHandler =
  return proc(
      peer: PeerId,
      pubsubTopic: Option[PubsubTopic],
      message: WakuMessage,
      autoSharding: Option[Sharding],
  ): Future[WakuLightPushResult] {.async.} =
    let resolvedTopic = extractPubsubTopic(pubsubTopic, message, autoSharding).valueOr:
      return err(error)

    # append RLN proof
    let msgWithProof = checkAndGenerateRLNProof(rlnPeer, message).valueOr:
      return lighpushErrorResult(LightPushErrorCode.OUT_OF_RLN_PROOF, error)

    (await wakuRelay.validateMessage(resolvedTopic, msgWithProof)).isOkOr:
      return lighpushErrorResult(LightPushErrorCode.INVALID_MESSAGE, $error)

    let publishedResult = await wakuRelay.publish(resolvedTopic, msgWithProof)

    if publishedResult.isErr():
      let msgHash = computeMessageHash(resolvedTopic, message).to0xHex()
      notice "Lightpush request has not been published to any peers",
        msg_hash = msgHash, reason = $publishedResult.error
      return mapPubishingErrorToPushResult(publishedResult.error)

    return lightpushSuccessResult(publishedResult.get().uint32)
