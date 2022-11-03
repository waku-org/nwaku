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
  libp2p/varint,
  ../utils/protobuf,
  ../utils/time,
  waku_rln_relay/waku_rln_relay_types

const
  MaxWakuMessageSize* = 1024 * 1024 # In bytes. Corresponds to PubSub default

type
  ContentTopic* = string

  WakuMessage* = object
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
    
   

# Encoding and decoding -------------------------------------------------------
proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage(ephemeral: false)
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)
  discard ? pb.getField(3, msg.version)

  var timestamp: zint64
  discard ? pb.getField(10, timestamp)
  msg.timestamp = Timestamp(timestamp)

  # XXX Experimental, this is part of https://rfc.vac.dev/spec/17/ spec
  var proofBytes: seq[byte]
  discard ? pb.getField(21, proofBytes)
  msg.proof = ? RateLimitProof.init(proofBytes)

  # Behaviour of ephemeral with storeTTL to be defined,
  # If a message is marked ephemeral, it should not have a storeTTL.
  # If a message is not marked ephemeral, it should have a storeTTL.
  # How would we handle messages that should be stored permanently?
  var ephemeral: uint
  if ? pb.getField(31, ephemeral):
    msg.ephemeral = bool(ephemeral)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write3(1, message.payload)
  result.write3(2, message.contentTopic)
  result.write3(3, message.version)
  result.write3(10, zint64(message.timestamp))
  result.write3(21, message.proof.encode())
  result.write3(31, uint64(message.ephemeral))
  result.finish3()

