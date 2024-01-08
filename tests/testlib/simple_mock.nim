# Sourced from https://forum.nim-lang.org/t/9255#60617

import posix

type
  Instr {.union.} = object
    bytes: array[8, byte]
    value: uint64

proc mockImpl*(target, replacement: pointer) =
  # YOLO who needs alignment
  #doAssert (cast[ByteAddress](target) and ByteAddress(0x07)) == 0
  var page = cast[pointer](cast[ByteAddress](target) and (not 0xfff))
  doAssert mprotect(page, 4096, PROT_WRITE or PROT_EXEC) == 0
  let rel = cast[ByteAddress](replacement) - cast[ByteAddress](target) - 5
  var
    instr =
      Instr(
        bytes: [
          0xe9.byte,
          (rel shr 0).byte,
          (rel shr 8).byte,
          (rel shr 16).byte,
          (rel shr 24).byte,
          0,
          0,
          0
        ]
      )
  cast[ptr uint64](target)[] = instr.value
  doAssert mprotect(page, 4096, PROT_EXEC) == 0

# Note: Requires manual cleanup
# Usage Example:
# proc helloWorld(): string = 
#   "Hello, World!"
#
# echo helloWorld() # "Hello, World!"
#
# let backup = helloWorld
# mock(helloWorld):
#   proc mockedHellWorld(): string =
#     "Mocked Hello, World!"
#   mockedMigrate
#
# echo helloWorld() # "Mocked Hello, World!"
# 
# helloWorld = backup  # Restore the original function
template mock*(target, replacement: untyped): untyped =
  mockImpl(cast[pointer](target), cast[pointer](replacement))

import std/macros
import std/[macros, genasts]

macro extractProc*(t: typed): untyped =
  if t.kind != nnkCall:
    error("Expected a call", t)
  t[0]

macro extractProcImpl2(call: typed): untyped =
  call[0]

macro extractProc2*(prc: typed, params: varargs[typed]): untyped =
  result = newCall(prc)
  for param in params:
    case param.kind
    of nnkVarTy:
      result.add:
        genast(typ = param[^1]):
          var param: typ
          param
    else:
      result.add newCall("default", param)
  result = newCall(bindSym"extractProcImpl2", result)

macro getProc*(sym: typed, types: varargs[typedesc]): untyped =
  for procSym in sym:
    let params = procSym.getImpl.params

    block verifyCheck:
      if (params.len - 1) != types.len:
        break verifyCheck

      for i in 1..<params.len:
        let paramTy = params[i]
        # params len is 1 greater than types len
        if paramTy[1] != types[i - 1]:
          break verifyCheck
      # if all the params are the same
      return procSym
