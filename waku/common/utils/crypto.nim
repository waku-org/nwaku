when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import libp2p/crypto/crypto as libp2pCrypto

export libp2pCrypto

type RngCtx = ref HmacDrbgContext

var rng {.threadvar.}: RngCtx

proc getRng*(): RngCtx =
  if rng == nil:
    rng = libp2pCrypto.newRng()
  return rng