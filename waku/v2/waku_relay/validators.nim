when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  chronicles,
  chronos,
  stew/byteutils,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/errors,
  nimcrypto/sha2,
  secp256k1

import
  ./protocol,
  ../waku_message

# Application level message hash
proc msgHash*(pubSubTopic: string, msg: WakuMessage): array[32, byte] =
  var ctx: sha256
  ctx.init()
  defer: ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())

  # TODO: Other fields?

  return ctx.finish()

proc addSignedTopicValidator*(w: WakuRelay, topic: PubsubTopic, publicTopicKey: SkPublicKey) =
  debug "adding validator to signed topic", topic=topic, publicTopicKey=publicTopicKey

  proc validator(topic: string, message: messages.Message): Future[errors.ValidationResult] {.async.} =
    let msg = WakuMessage.decode(message.data)
    if msg.isOk():
      let msgHash = SkMessage(topic.msgHash(msg.get))
      let recoveredSignature = SkSignature.fromRaw(msg.get.meta)
      if recoveredSignature.isErr():
        # TODO: add metrics for accept/reject
        return errors.ValidationResult.Reject
      if recoveredSignature.get.verify(msgHash, publicTopicKey):
        return errors.ValidationResult.Accept
      else:
        return errors.ValidationResult.Reject
    return errors.ValidationResult.Reject

  w.addValidator(topic, validator)
