## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.
##
## For payload content and encryption, see waku/v2/node/waku_payload.nim


{.push raises: [Defect].}

import
  libp2p/protobuf/minprotobuf
when defined(rln):
  import waku_rln_relay/waku_rln_relay_types

type
  ContentTopic* = string

  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: ContentTopic
    version*: uint32
    # sender generated timestamp
    timestamp*: float64
    # the proof field indicates that the message is not a spam
    # this field will be used in the rln-relay protocol
    # XXX Experimental, this is part of https://rfc.vac.dev/spec/17/ spec and not yet part of WakuMessage spec
    when defined(rln):
      proof*: RateLimitProof
    else:
      proof*: seq[byte]
   

# Encoding and decoding -------------------------------------------------------
proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)
  discard ? pb.getField(3, msg.version)

  discard ? pb.getField(4, msg.timestamp)
  # XXX Experimental, this is part of https://rfc.vac.dev/spec/17/ spec and not yet part of WakuMessage spec
  when defined(rln):
    var proofBytes: seq[byte]
    discard ? pb.getField(21, proofBytes)
    msg.proof = ? RateLimitProof.init(proofBytes)
  else:
    discard ? pb.getField(21, msg.proof)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, message.payload)
  result.write(2, message.contentTopic)
  result.write(3, message.version)
  result.write(4, message.timestamp)
  when defined(rln):
    result.write(21, message.proof.encode())
  else:
    result.write(21, message.proof)
