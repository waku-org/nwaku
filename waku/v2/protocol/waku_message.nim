## Waku Message module.
##
## See https://github.com/vacp2p/specs/blob/master/specs/waku/v2/waku-message.md
## for spec.
##
## For payload content and encryption, see waku/v2/node/waku_payload.nim


import
  libp2p/protobuf/minprotobuf

type
  ContentTopic* = uint32

  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: ContentTopic
    version*: uint32

# Encoding and decoding -------------------------------------------------------
proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)
  discard ? pb.getField(3, msg.version)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, message.payload)
  result.write(2, message.contentTopic)
  result.write(3, message.version)
