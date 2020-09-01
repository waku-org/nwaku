## Core Waku data types are defined here to avoid recursive dependencies.
##
## TODO Move more common data types here

import
  chronos,
  libp2p/[switch, peerinfo, multiaddress, crypto/crypto],
  libp2p/protobuf/minprotobuf

# Common data types -----------------------------------------------------------

type
  Topic* = string
  Message* = seq[byte]

  # NOTE based on Eth2Node in NBC eth2_network.nim
  WakuNode* = ref object of RootObj
    switch*: Switch
    peerInfo*: PeerInfo
    libp2pTransportLoops*: seq[Future[void]]
    messages*: seq[(Topic, Message)]

  WakuMessage* = object
    payload*: seq[byte]
    contentTopic*: string



# Encoding and decoding -------------------------------------------------------

proc init*(T: type WakuMessage, buffer: seq[byte]): ProtoResult[T] =
  var msg = WakuMessage()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, msg.payload)
  discard ? pb.getField(2, msg.contentTopic)

  ok(msg)

proc encode*(message: WakuMessage): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, message.payload)
  result.write(2, message.contentTopic)
