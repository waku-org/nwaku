when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/math,
  chronicles,
  chronos,
  metrics,
  stew/byteutils,
  stew/endians2,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/errors,
  nimcrypto/sha2,
  secp256k1

const MessageWindowInSec = 5 * 60 # +- 5 minutes

import ./external_config, ../waku_relay/protocol, ../waku_core

declarePublicCounter waku_msg_validator_signed_outcome,
  "number of messages for each validation outcome", ["result"]

# Application level message hash
proc msgHash*(pubSubTopic: string, msg: WakuMessage): array[32, byte] =
  var ctx: sha256
  ctx.init()
  defer:
    ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.timestamp.uint64.toBytes(Endianness.littleEndian))
  ctx.update(
    if msg.ephemeral:
      @[1.byte]
    else:
      @[0.byte]
  )

  return ctx.finish()

proc withinTimeWindow*(msg: WakuMessage): bool =
  # Returns true if the message timestamp is:
  # abs(now - msg.timestamp) < MessageWindowInSec
  let ts = msg.timestamp
  let now = getNowInNanosecondTime()
  let window = getNanosecondTime(MessageWindowInSec)

  if abs(now - ts) < window:
    return true
  return false

proc addSignedTopicsValidator*(w: WakuRelay, protectedTopics: seq[ProtectedTopic]) =
  debug "adding validator to signed topics"

  proc validator(
      topic: string, msg: WakuMessage
  ): Future[errors.ValidationResult] {.async.} =
    var outcome = errors.ValidationResult.Reject

    for protectedTopic in protectedTopics:
      if (protectedTopic.topic == topic):
        if msg.timestamp != 0:
          if msg.withinTimeWindow():
            let msgHash = SkMessage(topic.msgHash(msg))
            let recoveredSignature = SkSignature.fromRaw(msg.meta)
            if recoveredSignature.isOk():
              if recoveredSignature.get.verify(msgHash, protectedTopic.key):
                outcome = errors.ValidationResult.Accept

        if outcome != errors.ValidationResult.Accept:
          debug "signed topic validation failed",
            topic = topic, publicTopicKey = protectedTopic.key
        waku_msg_validator_signed_outcome.inc(labelValues = [$outcome])
        return outcome

    return errors.ValidationResult.Accept

  w.addValidator(validator, "signed topic validation failed")
