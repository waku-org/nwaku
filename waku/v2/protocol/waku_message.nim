## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.
##
## For payload content and encryption, see waku/v2/node/waku_payload.nim

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


import
  libp2p/protobuf/minprotobuf,
  libp2p/varint
import
  ../utils/protobuf,
  ../utils/time,
  ./waku_rln_relay/waku_rln_relay_types


const MaxWakuMessageSize* = 1024 * 1024 # In bytes. Corresponds to PubSub default

type
  PubsubTopic* = string
  ContentTopic* = string


type WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: ContentTopic
    version*: uint32
    # sender generated timestamp
    timestamp*: Timestamp
    # the proof field indicates that the message is not a spam
    # this field will be used in the rln-relay protocol
    # XXX Experimental, this is part of https://rfc.vac.dev/spec/17/ spec and not yet part of WakuMessage spec
    proof*: RateLimitProof
    # The ephemeral field indicates if the message should
    # be stored. bools and uints are 
    # equivalent in serialization of the protobuf
    ephemeral*: bool


## Encoding and decoding

proc encode*(message: WakuMessage): ProtoBuffer =
  var buf = initProtoBuffer()

  buf.write3(1, message.payload)
  buf.write3(2, message.contentTopic)
  buf.write3(3, message.version)
  buf.write3(10, zint64(message.timestamp))
  buf.write3(21, message.proof.encode())
  buf.write3(31, uint64(message.ephemeral))
  buf.finish3()

  buf

proc decode*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage(ephemeral: false)
  let pb = initProtoBuffer(buffer)

  discard ?pb.getField(1, msg.payload)
  discard ?pb.getField(2, msg.contentTopic)
  discard ?pb.getField(3, msg.version)

  var timestamp: zint64
  discard ?pb.getField(10, timestamp)
  msg.timestamp = Timestamp(timestamp)

  # XXX Experimental, this is part of https://rfc.vac.dev/spec/17/ spec
  var proofBytes: seq[byte]
  discard ?pb.getField(21, proofBytes)
  msg.proof = ?RateLimitProof.init(proofBytes)

  var ephemeral: uint
  if ?pb.getField(31, ephemeral):
    msg.ephemeral = bool(ephemeral)

  ok(msg)
