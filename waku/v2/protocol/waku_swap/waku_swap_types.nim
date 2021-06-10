import
  std/tables,
  bearssl,
  libp2p/protocols/protocol,
  libp2p/peerinfo,
  ../../node/peer_manager/peer_manager  

type
  # The Swap Mode determines the functionality available in the swap protocol.
  # It determines the kind of logs to be displayed as well as tests to run.
  # Refer to https://github/com/vacp2p/research/discussions/61 for more info on Swap Modes
  SwapMode* = enum
    Soft,
    Mock,
    Hard

  SwapConfig* = object
    mode* : SwapMode
    paymentThreshold* : int
    disconnectThreshold* : int

  Beneficiary* = seq[byte]

  # TODO Consider adding payment threshhold and terms field
  Handshake* = object
    beneficiary*: Beneficiary

  # XXX I'm confused by lack of signature here, most important thing...
  # TODO Look over these data structures again
  Cheque* = object
    beneficiary*: Beneficiary
    date*: uint32
    amount*: uint32
    signature*: seq[byte]

  CreditHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}
  DebitHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}
  ApplyPolicyHandler* = proc(peerId: PeerId) {.gcsafe, closure.}

  WakuSwap* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref BrHmacDrbgContext
    text*: string
    accounting*: Table[PeerId, int]
    credit*: CreditHandler
    debit*: DebitHandler
    applyPolicy*: ApplyPolicyHandler
    config*: SwapConfig
