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
  ../message_notifier,
  ./waku_swap_types

export waku_swap_types

declarePublicGauge waku_swap_peers, "number of swap peers"
declarePublicGauge waku_swap_errors, "number of swap protocol errors", ["type"]

logScope:
  topics = "wakuswap"

const WakuSwapCodec* = "/vac/waku/swap/2.0.0-alpha1"

# Serialization
# -------------------------------------------------------------------------------
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
# -------------------------------------------------------------------------------
#
# We credit and debits peers based on what for now is a form of Karma asset.

# TODO Test for credit/debit operations in succession

proc sendCheque*(ws: WakuSwap) {.async.} =
  # TODO Better peer selection, for now using hardcoded peer
  let peer = ws.peers[0]
  let conn = await ws.switch.dial(peer.peerInfo.peerId, peer.peerInfo.addrs, WakuSwapCodec)

  info "sendCheque"

  # TODO Add beneficiary, etc
  # XXX Hardcoded amount for now
  await conn.writeLP(Cheque(amount: 1).encode().buffer)

  # Set new balance
  # XXX Assume peerId is first peer
  let peerId = ws.peers[0].peerInfo.peerId
  ws.accounting[peerId] -= 1
  info "New accounting state", accounting = ws.accounting[peerId]

# TODO Authenticate cheque, check beneficiary etc
proc handleCheque*(ws: WakuSwap, cheque: Cheque) =
  info "handle incoming cheque"
  # XXX Assume peerId is first peer
  let peerId = ws.peers[0].peerInfo.peerId
  ws.accounting[peerId] += int(cheque.amount)
  info "New accounting state", accounting = ws.accounting[peerId]

proc init*(wakuSwap: WakuSwap) =
  info "wakuSwap init 1"
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    info "swap handle incoming connection"
    var message = await conn.readLp(64*1024)
    # XXX This can be handshake, etc
    var res = Cheque.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_swap_errors.inc(labelValues = ["decode_rpc_failure"])
      return

    info "received cheque", value=res.value
    wakuSwap.handleCheque(res.value)

  proc credit(peerId: PeerId, n: int) {.gcsafe, closure.} =
    info "Crediting peer for", peerId, n
    if wakuSwap.accounting.hasKey(peerId):
      wakuSwap.accounting[peerId] -= n
    else:
      wakuSwap.accounting[peerId] = -n
    info "Accounting state", accounting = wakuSwap.accounting[peerId]

    # TODO Isolate to policy function
    # TODO Tunable disconnect threshhold, hard code for PoC
    let disconnectThreshhold = 2
    if wakuSwap.accounting[peerId] >= disconnectThreshhold:
      info "Disconnect threshhold hit, disconnect peer"
    else:
      info "Disconnect threshhold not hit"

  # TODO Debit and credit here for Karma asset
  proc debit(peerId: PeerId, n: int) {.gcsafe, closure.} =
    info "Debiting peer for", peerId, n
    if wakuSwap.accounting.hasKey(peerId):
      wakuSwap.accounting[peerId] += n
    else:
      wakuSwap.accounting[peerId] = n
    info "Accounting state", accounting = wakuSwap.accounting[peerId]

    # TODO Isolate to policy function
    # TODO Tunable payment threshhold, hard code for PoC
    let paymentThreshhold = 1
    if wakuSwap.accounting[peerId] >= paymentThreshhold:
      info "Payment threshhold hit, send cheque"
      discard wakuSwap.sendCheque()
    else:
      info "Payment threshhold not hit"

  wakuSwap.handler = handle
  wakuSwap.codec = WakuSwapCodec
  wakuSwap.credit = credit
  wakuSwap.debit = debit

# TODO Expression return?
proc init*(T: type WakuSwap, switch: Switch, rng: ref BrHmacDrbgContext): T =
  info "wakuSwap init 2"
  new result
  result.rng = rng
  result.switch = switch
  result.accounting = initTable[PeerId, int]()
  result.text = "test"
  result.init()

proc setPeer*(ws: WakuSwap, peer: PeerInfo) =
  ws.peers.add(SwapPeer(peerInfo: peer))
  waku_swap_peers.inc()

# TODO End to end communication

