import ../waku_enr/capabilities

type GetShards* = proc(): seq[uint16] {.closure, gcsafe, raises: [].}

type GetCapabilities* = proc(): seq[Capabilities] {.closure, gcsafe, raises: [].}
