{.push raises: [].}

import std/[os, strutils], stew/byteutils, stew/ptrops

type SomePrimitives* = SomeInteger | enum | bool | SomeFloat | char

proc setValue*[T: SomePrimitives](key: string, val: openArray[T]) =
  os.putEnv(
    key, byteutils.toHex(makeOpenArray(val[0].unsafeAddr, byte, val.len * sizeof(T)))
  )

proc setValue*(key: string, val: SomePrimitives) =
  os.putEnv(key, byteutils.toHex(makeOpenArray(val.unsafeAddr, byte, sizeof(val))))

proc decodePaddedHex(
    hex: string, res: ptr UncheckedArray[byte], outputLen: int
) {.raises: [ValueError].} =
  # make it an even length
  let
    inputLen = hex.len and not 0x01
    numHex = inputLen div 2
    maxLen = min(outputLen, numHex)

  var
    offI = hex.len - maxLen * 2
    offO = outputLen - maxLen

  for i in 0 ..< maxLen:
    res[i + offO] =
      hex[2 * i + offI].readHexChar shl 4 or hex[2 * i + 1 + offI].readHexChar

  # write single nibble from odd length hex
  if (offO > 0) and (offI > 0):
    res[offO - 1] = hex[offI - 1].readHexChar

proc getValue*(key: string, outVal: var string) {.raises: [ValueError].} =
  let hex = os.getEnv(key)
  let size = (hex.len div 2) + (hex.len and 0x01)
  outVal.setLen(size)
  decodePaddedHex(hex, cast[ptr UncheckedArray[byte]](outVal[0].addr), size)

proc getValue*[T: SomePrimitives](
    key: string, outVal: var seq[T]
) {.raises: [ValueError].} =
  let hex = os.getEnv(key)
  let byteSize = (hex.len div 2) + (hex.len and 0x01)
  let size = (byteSize + sizeof(T) - 1) div sizeof(T)
  outVal.setLen(size)
  decodePaddedHex(hex, cast[ptr UncheckedArray[byte]](outVal[0].addr), size * sizeof(T))

proc getValue*[N, T: SomePrimitives](key: string, outVal: var array[N, T]) =
  let hex = os.getEnv(key)
  decodePaddedHex(hex, cast[ptr UncheckedArray[byte]](outVal[0].addr), sizeof(outVal))

proc getValue*(key: string, outVal: var SomePrimitives) {.raises: [ValueError].} =
  let hex = os.getEnv(key)
  decodePaddedHex(hex, cast[ptr UncheckedArray[byte]](outVal.addr), sizeof(outVal))

template uTypeIsPrimitives*[T](_: type seq[T]): bool =
  when T is SomePrimitives: true else: false

template uTypeIsPrimitives*[N, T](_: type array[N, T]): bool =
  when T is SomePrimitives: true else: false

template uTypeIsPrimitives*[T](_: type openArray[T]): bool =
  when T is SomePrimitives: true else: false

template uTypeIsRecord*(_: typed): bool =
  false

template uTypeIsRecord*[T](_: type seq[T]): bool =
  when T is (object or tuple): true else: false

template uTypeIsRecord*[N, T](_: type array[N, T]): bool =
  when T is (object or tuple): true else: false

func constructKey*(prefix: string, keys: openArray[string]): string =
  var newKey: string

  let envvarPrefix = prefix.strip().toUpper().multiReplace(("-", "_"), (" ", "_"))
  newKey.add(envvarPrefix)

  for k in keys:
    newKey.add("_")

    let envvarKey = k.toUpper().multiReplace(("-", "_"), (" ", "_"))
    newKey.add(envvarKey)

  newKey
