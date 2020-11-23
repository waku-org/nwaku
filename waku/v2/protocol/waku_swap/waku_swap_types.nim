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

  AccountHandler* = proc (peerId: PeerId, amount: int) {.gcsafe, closure.}

  WakuSwap* = ref object of LPProtocol
    switch*: Switch
    rng*: ref BrHmacDrbgContext
    #peers*: seq[PeerInfo]
    text*: string
    accounting*: Table[PeerId, int]
    accountFor*: AccountHandler
