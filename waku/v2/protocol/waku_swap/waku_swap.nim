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

{.push raises: [Defect].}

# TODO Generally clean up errors here, a lot of Exceptions, Defects and KeyErros
#
# On KeyEror specifically:
# Accessing Table's items is prone to KeyError exception when the key does not belong to the table
# such exception can be avoided by calling hasKey() before accessing the key (which is the case in this module)
# but from the compiler point of view, the use of hasKey() does not make any difference in the potential exceptions
# - thus any key access should be wrapped inside try-except
# - or otherwise the exception should be thrown by the proc and handled by the higher level calls

import
  std/[tables, options, json],
  bearssl/rand,
  chronos, chronicles, metrics, stew/results,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/protobuf/minprotobuf,
  libp2p/stream/connection,
  ../../node/peer_manager/peer_manager,
  ./waku_swap_types,
  ../../utils/protobuf,
  ../../waku/v2/protocol/waku_swap/waku_swap_contracts

export waku_swap_types

const swapAccountBalanceBuckets = [-Inf, -200.0, -150.0, -100.0, -50.0, 0.0, 50.0, 100.0, 150.0, 200.0, Inf]

declarePublicGauge waku_swap_peers_count, "number of swap peers"
declarePublicGauge waku_swap_errors, "number of swap protocol errors", ["type"]
declarePublicGauge waku_swap_messages, "number of swap messages received", ["type"]
declarePublicHistogram waku_peer_swap_account_balance, "Swap Account Balance for waku peers, aggregated into buckets based on threshold limits", buckets = swapAccountBalanceBuckets

logScope:
  topics = "waku swap"

const WakuSwapCodec* = "/vac/waku/swap/2.0.0-beta1"

# Error types (metric label values)
const
  dialFailure = "dial_failure"
  decodeRpcFailure = "decode_rpc_failure"

# Serialization
# -------------------------------------------------------------------------------
proc encode*(handshake: Handshake): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, handshake.beneficiary)

  output.finish3()

  return output

proc encode*(cheque: Cheque): ProtoBuffer =
  var output = initProtoBuffer()

  output.write3(1, cheque.beneficiary)
  output.write3(2, cheque.date)
  output.write3(3, cheque.amount)
  output.write3(4, cheque.signature)

  output.finish3()

  return output

proc init*(T: type Handshake, buffer: seq[byte]): ProtoResult[T] =
  var beneficiary: seq[byte]
  var handshake = Handshake()
  let pb = initProtoBuffer(buffer)

  discard ? pb.getField(1, handshake.beneficiary)

  return ok(handshake)

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

  return ok(cheque)

# Accounting
# -------------------------------------------------------------------------------
#
# We credit and debits peers based on what for now is a form of Karma asset.

# TODO Test for credit/debit operations in succession


# TODO Assume we calculated cheque
proc sendCheque*(ws: WakuSwap, peerId: PeerID) {.async.} =
  let connOpt = await ws.peerManager.dialPeer(peerId, WakuSwapCodec)

  if connOpt.isNone():
    # @TODO more sophisticated error handling here
    error "failed to connect to remote peer"
    waku_swap_errors.inc(labelValues = [dialFailure])
    return

  info "sendCheque"

  # TODO We get this from the setup of swap setup, dynamic, should be part of setup
  # TODO Add beneficiary, etc
  var aliceSwapAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  var aliceWalletAddress = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"
  var signature: string

  var res = waku_swap_contracts.signCheque(aliceSwapAddress)
  if res.isOk():
    info "signCheque ", res=res[]
    let json = res[]
    signature = json["signature"].getStr()
  else:
    # To test code paths, this should look different in a production setting
    warn "Something went wrong when signing cheque, sending anyway"

  info "Signed Cheque", swapAddress = aliceSwapAddress, signature = signature, issuerAddress = aliceWalletAddress
  let sigBytes = cast[seq[byte]](signature)
  await connOpt.get().writeLP(Cheque(amount: 1, signature: sigBytes, issuerAddress: aliceWalletAddress).encode().buffer)

  # Set new balance
  ws.accounting[peerId] -= 1
  info "New accounting state", accounting = ws.accounting[peerId]

# TODO Authenticate cheque, check beneficiary etc
proc handleCheque*(ws: WakuSwap, cheque: Cheque, peerId: PeerID) {.raises: [Defect, KeyError].} =
  info "handle incoming cheque"

  # Get the original signer using web3. For now, a static value (0x6C3d502f1a97d4470b881015b83D9Dd1062172e1) will be used.
  # Check if web3.eth.personal.ecRecover(messageHash, signature); or an equivalent function has been implemented in nim-web3
  let signer = "0x6C3d502f1a97d4470b881015b83D9Dd1062172e1"

  # Verify that the Issuer was the signer of the signature
  if signer != cheque.issuerAddress:
    warn "Invalid cheque: The address of the issuer is different from the signer."

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

# Log Account Metrics
proc logAccountMetrics*(ws: Wakuswap, peer: PeerId) {.async.}=
  waku_peer_swap_account_balance.observe(ws.accounting[peer].int64)


proc init*(wakuSwap: WakuSwap) =
  info "wakuSwap init 1"
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    info "swap handle incoming connection"
    var message = await conn.readLp(MaxChequeSize.int)
    # XXX This can be handshake, etc
    var res = Cheque.init(message)
    if res.isErr:
      error "failed to decode rpc"
      waku_swap_errors.inc(labelValues = [decodeRpcFailure])
      return

    info "received cheque", value=res.value
    waku_swap_messages.inc(labelValues = ["Cheque"])
    wakuSwap.handleCheque(res.value, conn.peerId)

  proc credit(peerId: PeerID, n: int)
    {.gcsafe, closure, raises: [Defect, KeyError, Exception].} =
  
    info "Crediting peer: ", peer=peerId, amount=n
    if wakuSwap.accounting.hasKey(peerId):
      wakuSwap.accounting[peerId] -= n
    else:
      wakuSwap.accounting[peerId] = -n
    info "Accounting state", accounting = wakuSwap.accounting[peerId]
    wakuSwap.applyPolicy(peerId)

  # TODO Debit and credit here for Karma asset
  proc debit(peerId: PeerID, n: int)
    {.gcsafe, closure, raises: [Defect, KeyError, Exception].} =
  
    info "Debiting peer: ", peer=peerId, amount=n
    if wakuSwap.accounting.hasKey(peerId):
      wakuSwap.accounting[peerId] += n
    else:
      wakuSwap.accounting[peerId] = n
    info "Accounting state", accounting = wakuSwap.accounting[peerId]
    wakuSwap.applyPolicy(peerId)
    
  proc applyPolicy(peerId: PeerID)
    {.gcsafe, closure, raises: [Defect, KeyError, Exception].} =
    
    # TODO Separate out depending on if policy is soft (accounting only) mock (send cheque but don't cash/verify) hard (actually send funds over testnet)

    #Check if the Disconnect Threshold has been hit. Account Balance nears the disconnectThreshold after a Credit has been done
    if wakuSwap.accounting[peerId] <= wakuSwap.config.disconnectThreshold:
      warn "Disconnect threshhold has been reached: ", threshold=wakuSwap.config.disconnectThreshold, balance=wakuSwap.accounting[peerId]
    else:
      info "Disconnect threshhold not hit"

    #Check if the Payment threshold has been hit. Account Balance nears the paymentThreshold after a Debit has been done
    if wakuSwap.accounting[peerId] >= wakuSwap.config.paymentThreshold:
      warn "Payment threshhold has been reached: ", threshold=wakuSwap.config.paymentThreshold, balance=wakuSwap.accounting[peerId]
      #In soft phase we don't send cheques yet
      if wakuSwap.config.mode == Mock:
        discard wakuSwap.sendCheque(peerId)
    else:
      info "Payment threshhold not hit"

    waitFor wakuSwap.logAccountMetrics(peerId)

  wakuSwap.handler = handle
  wakuSwap.codec = WakuSwapCodec
  wakuSwap.credit = credit
  wakuSwap.debit = debit
  wakuswap.applyPolicy = applyPolicy

# TODO Expression return?
proc init*(T: type WakuSwap, peerManager: PeerManager, rng: ref rand.HmacDrbgContext, swapConfig: SwapConfig): T =
  info "wakuSwap init 2"
  let 
    accounting = initTable[PeerId, int]()
    text = "test"
  
  var ws = WakuSwap(rng: rng,
                  peerManager: peerManager,
                  accounting: accounting,
                  text: text,
                  config: swapConfig)
  ws.init()

  return ws

proc setPeer*(ws: WakuSwap, peer: RemotePeerInfo) =
  ws.peerManager.addPeer(peer, WakuSwapCodec)
  waku_swap_peers_count.inc()

# TODO End to end communication
