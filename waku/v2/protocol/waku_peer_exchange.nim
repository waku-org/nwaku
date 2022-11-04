when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ./waku_peer_exchange/rpc,
  ./waku_peer_exchange/rpc_codec,
  ./waku_peer_exchange/protocol
export
  rpc,
  rpc_codec,
  protocol
