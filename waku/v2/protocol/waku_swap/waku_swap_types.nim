import
  std/tables,
  bearssl,
  libp2p/protocols/protocol,
  libp2p/peerinfo,
  ../../node/peer_manager  

type
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

  WakuSwap* = ref object of LPProtocol
    peerManager*: PeerManager
    rng*: ref BrHmacDrbgContext
    text*: string
    accounting*: Table[PeerId, int]
    credit*: CreditHandler
    debit*: DebitHandler
