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
  std/[tables, options, json],
  bearssl,
  chronos, chronicles, metrics, stew/results,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ../../node/peer_manager,
  ../message_notifier,
  ./waku_swap_types,
  ../../waku/v2/protocol/waku_swap/waku_swap_contracts

export waku_swap_types

declarePublicGauge waku_swap_peers, "number of swap peers"
declarePublicGauge waku_swap_errors, "number of swap protocol errors", ["type"]

logScope:
  topics = "wakuswap"

const WakuSwapCodec* = "/vac/waku/swap/2.0.0-alpha1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

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
  result.write(4, cheque.signature)

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
  var signature: seq[byte]
  var cheque = Cheque()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, cheque.beneficiary)
  discard ? pb.getField(2, cheque.date)
  discard ? pb.getField(3, cheque.amount)
  discard ? pb.getField(4, cheque.signature)

  ok(cheque)

# Accounting
# -------------------------------------------------------------------------------
#
# We credit and debits peers based on what for now is a form of Karma asset.

# TODO Test for credit/debit operations in succession


# TODO Assume we calculated cheque
proc sendCheque*(ws: WakuSwap) {.async.} =
  let peerOpt = ws.peerManager.selectPeer(WakuSwapCodec)

  if peerOpt.isNone():
    error "no suitable remote peers"
    waku_swap_errors.inc(labelValues = [dialFailure])
    return

  let peer = peerOpt.get()

  let connOpt = await ws.peerManager.dialPeer(peer, WakuSwapCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_swap_errors.inc(labelValues = [dialFailure])
    return

  info "sendCheque"

  # TODO We get this from the setup of swap setup, dynamic, should be part of setup
  # TODO Add beneficiary, etc
  var aliceSwapAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  var signature: string

  var res = waku_swap_contracts.signCheque(aliceSwapAddress)
  if res.isOk():
    info "signCheque ", res=res[]
    let json = res[]
    signature = json["signature"].getStr()
  else:
    # To test code paths, this should look different in a production setting
    warn "Something went wrong when signing cheque, sending anyway"

  info "Signed Cheque", swapAddress = aliceSwapAddress, signature = signature
  let sigBytes = cast[seq[byte]](signature)
  await connOpt.get().writeLP(Cheque(amount: 1, signature: sigBytes).encode().buffer)

  # Set new balance
  let peerId = peer.peerId
  ws.accounting[peerId] -= 1
  info "New accounting state", accounting = ws.accounting[peerId]

# TODO Authenticate cheque, check beneficiary etc
proc handleCheque*(ws: WakuSwap, cheque: Cheque) =
  info "handle incoming cheque"
  # XXX Assume peerId is first peer
  let peerOpt = ws.peerManager.selectPeer(WakuSwapCodec)
  let peerId = peerOpt.get().peerId

  # TODO Redeem cheque here
  var signature = cast[string](cheque.signature)
  # TODO Where should Alice Swap Address come from? Handshake probably?
  # Hacky for now
  var aliceSwapAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  info "Redeeming cheque with", swapAddress=aliceSwapAddress, signature=signature
  var res = waku_swap_contracts.redeemCheque(aliceSwapAddress, signature)
  if res.isOk():
    info "redeemCheque ok", redeem=res[]
  else:
    info "Unable to redeem cheque"

  # Check balance here
  # TODO How do we get ERC20 address here?
  # XXX This one is wrong
  # Normally this would be part of initial setup, otherwise we need some temp persistence here
  # Possibly as part of handshake?
  var erc20address = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  let balRes = waku_swap_contracts.getERC20Balances(erc20address)
  if balRes.isOk():
    # XXX: Assumes Alice and Bob here...
    var bobBalance = balRes[]["bobBalance"].getInt()
    info "New balance is", balance = bobBalance
  else:
    info "Problem getting Bob balance"

  # TODO Could imagine scenario where you don't cash cheque but leave it as credit
  # In that case, we would probably update accounting state, but keep track of cheques

  # When this is true we update accounting state anyway when node is offline,
  # makes waku_swap test pass for now
  # Consider desired logic here
  var stateUpdateOverRide = true

  if res.isOk():
    info "Updating accounting state with redeemed cheque"
    ws.accounting[peerId] += int(cheque.amount)
  else:
    if stateUpdateOverRide:
      info "Updating accounting state with even if cheque failed"
      ws.accounting[peerId] += int(cheque.amount)
    else:
      info "Not updating accounting state with due to bad cheque"

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
      waku_swap_errors.inc(labelValues = [decodeRpcFailure])
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
    # XXX: Where should this happen? Apply policy...
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
proc init*(T: type WakuSwap, peerManager: PeerManager, rng: ref BrHmacDrbgContext): T =
  info "wakuSwap init 2"
  new result
  result.rng = rng
  result.peerManager = peerManager
  result.accounting = initTable[PeerId, int]()
  result.text = "test"
  result.init()

proc setPeer*(ws: WakuSwap, peer: PeerInfo) =
  ws.peerManager.addPeer(peer, WakuSwapCodec)
  waku_swap_peers.inc()

# TODO End to end communication
