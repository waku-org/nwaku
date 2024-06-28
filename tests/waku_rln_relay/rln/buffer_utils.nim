import waku_rln_relay/rln/rln_interface

proc `==`*(a: Buffer, b: seq[uint8]): bool =
  if a.len != uint(b.len):
    return false

  let bufferArray = cast[ptr UncheckedArray[uint8]](a.ptr)
  for i in 0 ..< b.len:
    if bufferArray[i] != b[i]:
      return false
  return true
