## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.

{.push raises: [].}

import
  std/[sequtils, unicode], stew/[byteutils, endians2, arrayops], nimcrypto/sha2, results
import
  logos_delivery/kernel/[
    common/protobuf,
    common/parse_size_units,
    common/topics/content_topic,
    common/topics/pubsub_topic,
    common/time,
  ]
const MaxMetaAttrLength* = 64 # 64 bytes

const
  ## https://rfc.vac.dev/spec/64/#message-size
  DefaultMaxWakuMessageSizeStr* = "150KiB" # Remember that 1 MiB is the PubSub default
  DefaultMaxWakuMessageSize* = parseCorrectMsgSize(DefaultMaxWakuMessageSizeStr)

  DefaultSafetyBufferProtocolOverhead* = 64 * 1024 # overhead measured in bytes

# The fields are in field number order, because the library writes them in
# declaration order. The gossipsub message id is a hash of the encoded bytes,
# so the field order must be the same as in other implementations.
type WakuMessage* {.proto3.} = object # Data payload transmitted.
  payload* {.fieldNumber: 1.}: seq[byte]
  # String identifier that can be used for content-based filtering.
  contentTopic* {.fieldNumber: 2.}: ContentTopic
  # Number to discriminate different types of payload encryption.
  # Compatibility with Whisper/WakuV1.
  version* {.fieldNumber: 3, pint.}: uint32
  # Sender generated timestamp.
  timestamp* {.fieldNumber: 10, sint.}: Timestamp
  # Application specific metadata.
  meta* {.fieldNumber: 11.}: seq[byte]
  # Part of RFC 17: https://rfc.vac.dev/spec/17/
  # The proof attribute indicates that the message is not spam. This
  # attribute will be used in the rln-relay protocol.
  proof* {.fieldNumber: 21.}: seq[byte]
  # The ephemeral attribute marks a message that a store node does not keep.
  ephemeral* {.fieldNumber: 31.}: bool

proc ensureTimestampSet*(message: WakuMessage): WakuMessage =
  result = message
  if result.timestamp == 0:
    result.timestamp = getNowInNanosecondTime()

## Encoding and decoding
# See:
# - RFC 14: https://rfc.vac.dev/spec/14/
# - Proto definition: https://github.com/vacp2p/waku/blob/main/waku/message/v1/message.proto

proc validateWakuMessageFields*(msg: WakuMessage): ProtobufResult[void] =
  ## Refuses a missing message, a message without a valid content topic, and
  ## a `meta` above `MaxMetaAttrLength`. Codecs call it for a nested
  ## `WakuMessage`, and the relay calls it before a send. At decode, the
  ## library refuses a `string` that is not valid UTF-8 before this proc runs,
  ## so the UTF-8 check of this proc has an effect only before a send.
  if msg == default(WakuMessage):
    return err(ProtobufError.missingRequiredField("message"))
  if msg.contentTopic.len == 0:
    return err(ProtobufError.missingRequiredField("content_topic"))
  if validateUtf8(msg.contentTopic) != -1:
    return err(ProtobufError.decodeFailure("content_topic is not valid UTF-8"))
  if msg.meta.len > MaxMetaAttrLength:
    return err(ProtobufError.invalidLengthField("meta"))
  ok()

protobufCodec(WakuMessage, validateWakuMessageFields)

## 14/WAKU2-MESSAGE: Deterministic message hashing
## https://rfc.vac.dev/spec/14/#deterministic-message-hashing

type WakuMessageHash* = array[32, byte]

func shortLog*(hash: WakuMessageHash): string =
  ## Returns compact string representation of ``WakuMessageHash``.
  var hexhash = newStringOfCap(13)
  hexhash &= hash.toOpenArray(0, 1).to0xHex()
  hexhash &= "..."
  hexhash &= hash.toOpenArray(hash.len - 2, hash.high).toHex()
  hexhash

func `$`*(hash: WakuMessageHash): string =
  shortLog(hash)

func to0xHex*(hash: WakuMessageHash): string =
  var hexhash = newStringOfCap(64)
  hexhash &= hash.toOpenArray(hash.low, hash.high).to0xHex()
  hexhash

const EmptyWakuMessageHash*: WakuMessageHash = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0,
]

converter fromBytes*(array: openArray[byte]): WakuMessageHash =
  var hash: WakuMessageHash
  discard copyFrom(hash, array)
  hash

converter toBytesArray*(digest: MDigest[256]): WakuMessageHash =
  digest.data

converter toBytes*(digest: MDigest[256]): seq[byte] =
  toSeq(digest.data)

proc hexToHash*(hexString: string): Result[WakuMessageHash, string] =
  var hash: WakuMessageHash

  try:
    hash = hexString.hexToSeqByte().fromBytes()
  except ValueError as e:
    return err("Exception converting hex string to hash: " & e.msg)

  return ok(hash)

proc computeMessageHash*(pubsubTopic: PubsubTopic, msg: WakuMessage): WakuMessageHash =
  var ctx: sha256
  ctx.init()
  defer:
    ctx.clear()

  ctx.update(pubsubTopic.toBytes())
  ctx.update(msg.payload)
  ctx.update(msg.contentTopic.toBytes())
  ctx.update(msg.meta)
  ctx.update(toBytesBE(uint64(msg.timestamp)))

  return ctx.finish() # Computes the hash

proc cmp*(x, y: WakuMessageHash): int =
  if x < y:
    return -1
  elif x == y:
    return 0

  return 1
