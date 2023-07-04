when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}


type WakuPeer* = object
    multiaddr*: string
    protocol*: string
    connected*: bool
