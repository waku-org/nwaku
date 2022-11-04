when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import stew/[results, byteutils, base64]


type Base64String* = distinct string


proc encode*(t: type Base64String, value: string|seq[byte]): Base64String =
  let val = block:
    when value is string:
      toBytes(value)
    else:
      value
  Base64String(base64.encode(Base64, val))

proc decode*(t: Base64String): Result[seq[byte], cstring] =
  try:
    ok(base64.decode(Base64, string(t)))
  except:
    err("failed to decode base64 string")

proc `$`*(t: Base64String): string {.inline.}=
  string(t)

proc `==`*(lhs: Base64String|string, rhs: Base64String|string): bool {.inline.}=
  string(lhs) == string(rhs)