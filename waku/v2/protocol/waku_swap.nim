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

import
  std/[tables, options],
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/switch,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ./message_notifier,
  ../waku_types

export waku_types

logScope:
  topics = "wakuswap"

const WakuSwapCodec* = "/vac/waku/swap/2.0.0-alpha1"

type
  Beneficiary* = seq[byte]

  # TODO Consider adding payment threshhold and terms field
  Handshake* = object
    beneficiary*: Beneficiary

  Cheque* = object
    beneficiary*: Beneficiary
    date*: uint32
    amount*: uint32

  AccountUpdateFunc* = proc(peerId: PeerId, amount: int) {.gcsafe.}

  AccountHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}

  WakuSwap* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    #peers*: seq[PeerInfo]
    text*: string
    accounting*: Table[PeerId, int]
    accountFor*: AccountHandler

proc encode*(handshake: Handshake): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, handshake.beneficiary)

proc encode*(cheque: Cheque): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, cheque.beneficiary)
  result.write(2, cheque.date)
  result.write(3, cheque.amount)

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
  discard ? pb.getField(3, cheque.amount)

  ok(cheque)


# Accounting
#

proc init*(wakuSwap: WakuSwap) =
  info "wakuSwap init 1"
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    info "NYI swap handle incoming connection"

  proc accountFor(peerId: PeerId, n: int) {.gcsafe, closure.} =
    info "Accounting for", peerId, n
    info "Accounting test", text = wakuSwap.text
    # Nicer way to write this?
    if wakuSwap.accounting.hasKey(peerId):
      wakuSwap.accounting[peerId] += n
    else:
      wakuSwap.accounting[peerId] = n
    info "Accounting state", accounting = wakuSwap.accounting[peerId]

  wakuSwap.handler = handle
  wakuSwap.codec = WakuSwapCodec
  wakuSwap.accountFor = accountFor


proc init*(T: type WakuSwap, switch: Switch, rng: ref BrHmacDrbgContext): T =
  info "wakuSwap init 2"
  new result
  result.rng = rng
  result.switch = switch
  result.accounting = initTable[PeerId, int]()
  result.text = "test"
  result.init()

# TODO End to end communication
