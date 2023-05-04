when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  chronos,
  metrics,
  stew/byteutils,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/errors,
  nimcrypto/sha2,
  secp256k1

import
  ../../waku/v2/waku_relay/protocol,
  ../../waku/v2/waku_core

declarePublicCounter waku_msg_validator_signed_outcome, "number of messages for each validation outcome", ["result"]

# Application level message hash
proc msgHash*(pubSubTopic: string, msg: WakuMessage): array[32, byte] =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())

  return ctx.finish()

proc addSignedTopicValidator*(w: WakuRelay, topic: PubsubTopic, publicTopicKey: SkPublicKey) =
  debug "adding validator to signed topic", topic=topic, publicTopicKey=publicTopicKey

  proc validator(topic: string, message: messages.Message): Future[errors.ValidationResult] {.async.} =
    let msg = WakuMessage.decode(message.data)
    var outcome = errors.ValidationResult.Reject

    if msg.isOk():
      let msgHash = SkMessage(topic.msgHash(msg.get))
      let recoveredSignature = SkSignature.fromRaw(msg.get.meta)
      if recoveredSignature.isOk():
        if recoveredSignature.get.verify(msgHash, publicTopicKey):
          outcome = errors.ValidationResult.Accept

    waku_msg_validator_signed_outcome.inc(labelValues = [$outcome])
    return outcome

  w.addValidator(topic, validator)
