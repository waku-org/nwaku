
proc alloc*(str: cstring): cstring =
  # Byte allocation from the given address.
  # There should be the corresponding manual deallocation with deallocShared !
  let ret = cast[cstring](allocShared0(len(str) + 1))
  copyMem(ret, str, len(str) + 1)
  return ret
