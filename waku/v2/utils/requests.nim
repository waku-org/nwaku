# Request utils.

{.push raises: [Defect].}

import bearssl, stew/byteutils

proc generateRequestId*(rng: ref BrHmacDrbgContext): string =
  var bytes: array[10, byte]
  brHmacDrbgGenerate(rng[], bytes)
  return toHex(bytes)
