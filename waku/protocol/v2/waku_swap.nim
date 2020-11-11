import
  std/tables,
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  libp2p/crypto/crypto,
  libp2p/switch,
  ./../../node/v2/waku_types

## SWAP implements Accounting for Waku. See
## https://github.com/vacp2p/specs/issues/24 for more.
##
## This is based on the SWAP based approach researched by the Swarm team, and
## can be thought of as an economic extension to Bittorrent's tit-for-tat
## economics.
##
## It is quite suitable for accounting for imbalances between peers, and
## specifically for something like the Store protocol.
##
## It is structured as follows:
##
## 1) First a handshake is made, where terms are agreed upon
##
## 2) Then operation occurs as normal with HistoryRequest, HistoryResponse etc
## through store protocol (or otherwise)
##
## 3) When payment threshhold is met, a cheque is sent. This acts as promise to
## pay. Right now it is best thought of as karma points.
##
## Things like settlement is for future work.
##

  logScope:
    topics = "wakuswap"

  const
    WakuSwapCodec* = "/vac/waku/swap/2.0.0-alpha1"

proc encode*(handshake: Handshake): ProtuBuffer =
  result = initProtoBuffer()
  result.write(1, handshake.beneficiary)

proc encode*(cheque: Cheque): ProtuBuffer =
  result = initProtoBuffer()
  result.write(1, handshake.beneficiary)
  result.write(2, handshake.date)
  result.write(3, handshake.amount)

proc init*(T: type Handshake, buffer: seq[byte]): ProtoResult[T] =
  var beneficiary: seq[byte]
  var handshake = Handshake()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, handshake.beneficiary)

  ok(handshake)

proc init*(T: type Cheque, buffer: seq[byte]): ProtoResult[T] =
  var beneficiary: seq[byte]
  var date: uint32
  var amount: uint32
  var cheque = Cheque()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, cheque.beneficiary)
  discard ? pb.getField(2, cheque.date)
  discard ? pb.getField(2, cheque.amount)

  ok(cheque)
