import libp2p/multiaddress,
       libp2p/crypto/crypto,
       libp2p/protocols/protocol,
       libp2p/peerinfo,
       standard_setup

type WakuRelayProto* = ref object of LPProtocol
  switch*: Switch
  conn*: Connection
  connected*: bool
  started*: bool
