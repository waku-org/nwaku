when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[math, strutils],
  chronicles,
  chronos,
  metrics,
  stew/byteutils,
  stew/endians2,
  stew/results,
  libp2p/protocols/pubsub/gossipsub,
  libp2p/protocols/pubsub/rpc/messages,
  libp2p/protocols/pubsub/errors,
  nimcrypto/sha2,
  nimcrypto/keccak,
  eth/keys

const MessageWindowInSec = 5*60 # +- 5 minutes

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
  ctx.update(msg.timestamp.uint64.toBytes(Endianness.littleEndian))
  ctx.update(if msg.ephemeral: @[1.byte] else: @[0.byte])

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

proc getKeyFromTopic*(protectedTopic: PubsubTopic): Result[string, string] =
  # example: /waku/2/signed:0x2ea1f2ec2da14e0e3118e6c5bdfa0631785c76cd/proto
  # see https://rfc.vac.dev/spec/57/#dos-protection
  let topicTag = "signed"
  let parts = protectedTopic.split("/")
  if parts.len != 5:
    return err("invalid topic format for a signed protected topic, missing fields")

  let topicName = parts[3]
  let topicParts = topicName.split(":")
  if topicParts.len != 2:
    return err("invalid topic format for a signed protected topic, : missing")

  if topicTag notin topicName:
    return err("invalid topic format expected signed: tag")

  let address = topicParts[1]
  if not address.startsWith("0x") or address.len != 42:
    return err("invalid address, expected 0x prefix and size of 42 chars")

  return ok(address)

proc addSignedTopicValidator*(w: WakuRelay, protectedTopic: PubsubTopic) =

  # address (hashed pubkey) to validate the message is encoded in the pubsub topic
  let address0x = getKeyFromTopic(protectedTopic)
  if address0x.isErr():
    raise newException(Defect, address0x.error)

  debug "adding validator to signed topic", protectedTopic=protectedTopic, address0x=address0x.get

  proc validator(protectedTopic: string, message: messages.Message): Future[errors.ValidationResult] {.async.} =
    let msg = WakuMessage.decode(message.data)
    var outcome = errors.ValidationResult.Reject

    if msg.isOk():
      if msg.get.timestamp != 0:
        if msg.get.withinTimeWindow():
          let signature = Signature.fromRaw(msg.get.meta)
          if signature.isOk():
            let msgHash = protectedTopic.msgHash(msg.get)
            let recoveredPublic = signature.get.recover(msgHash)
            if recoveredPublic.isOk():
              if recoveredPublic.get.toAddress() == address0x.get:
                outcome = errors.ValidationResult.Accept

    waku_msg_validator_signed_outcome.inc(labelValues = [$outcome])
    return outcome

  w.addValidator(protectedTopic, validator)
