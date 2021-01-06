# Request utils.

import bearssl, stew/byteutils

proc generateRequestId*(rng: ref BrHmacDrbgContext): string =
  var bytes: array[10, byte]
  brHmacDrbgGenerate(rng[], bytes)
  toHex(bytes)
