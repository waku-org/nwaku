import
  std/tables,
  bearssl,
  libp2p/protocols/protocol,
  libp2p/switch,
  libp2p/peerinfo

type
  Beneficiary* = seq[byte]

  # TODO Consider adding payment threshhold and terms field
  Handshake* = object
    beneficiary*: Beneficiary

  Cheque* = object
    beneficiary*: Beneficiary
    date*: uint32
    amount*: uint32

  CreditHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}
  DebitHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}

  SwapPeer* = object
    peerInfo*: PeerInfo

  WakuSwap* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    peers*: seq[SwapPeer]
    text*: string
    accounting*: Table[PeerId, int]
    credit*: CreditHandler
    debit*: DebitHandler
