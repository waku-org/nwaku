when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  ./waku_filter/rpc,
  ./waku_filter/rpc_codec,
  ./waku_filter/protocol

export
  rpc,
  rpc_codec,
  protocol
