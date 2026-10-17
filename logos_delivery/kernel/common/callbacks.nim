import
  logos_delivery/kernel/enr/capabilities,
  logos_delivery/kernel/protocols/rendezvous/peer_record

type GetShards* = proc(): seq[uint16] {.closure, gcsafe, raises: [].}

type GetCapabilities* = proc(): seq[Capabilities] {.closure, gcsafe, raises: [].}

type GetWakuPeerRecord* = proc(): WakuPeerRecord {.closure, gcsafe, raises: [].}
