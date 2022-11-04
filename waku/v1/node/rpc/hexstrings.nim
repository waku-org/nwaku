# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements the Ethereum hexadecimal string formats for JSON
## See: https://github.com/ethereum/wiki/wiki/JSON-RPC#hex-value-encoding

#[
  Note:
  The following types are converted to hex strings when marshalled to JSON:
    * Hash256
    * UInt256
    * seq[byte]
    * openArray[seq]
    * PublicKey
    * PrivateKey
    * SymKey
    * Topic
    * Bytes
]#

import
  stint, stew/byteutils, eth/keys, eth/common/eth_types,
  ../../protocol/waku_protocol

type
  HexDataStr* = distinct string
  Identifier* = distinct string        # 32 bytes, no 0x prefix!
  HexStrings = HexDataStr | Identifier

# Hex validation

template hasHexHeader(value: string): bool =
  if value.len >= 2 and value[0] == '0' and value[1] in {'x', 'X'}: true
  else: false

template isHexChar(c: char): bool =
  if  c notin {'0'..'9'} and
      c notin {'a'..'f'} and
      c notin {'A'..'F'}: false
  else: true

func isValidHexQuantity*(value: string): bool =
  if not value.hasHexHeader:
    return false
  # No leading zeros (but allow 0x0)
  if value.len < 3 or (value.len > 3 and value[2] == '0'): return false
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

func isValidHexData*(value: string, header = true): bool =
  if header and not value.hasHexHeader:
    return false
  # Must be even number of digits
  if value.len mod 2 != 0: return false
  # Leading zeros are allowed
  for i in 2 ..< value.len:
    let c = value[i]
    if not c.isHexChar:
      return false
  return true

template isValidHexData(value: string, hexLen: int, header = true): bool =
  value.len == hexLen and value.isValidHexData(header)

func isValidIdentifier*(value: string): bool =
  # 32 bytes for Whisper ID, no 0x prefix
  result = value.isValidHexData(64, false)

func isValidPublicKey*(value: string): bool =
  # 65 bytes for Public Key plus 1 byte for 0x prefix
  result = value.isValidHexData(132)

func isValidPrivateKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidSymKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidHash256*(value: string): bool =
  # 32 bytes for Hash256 plus 1 byte for 0x prefix
  result = value.isValidHexData(66)

func isValidTopic*(value: string): bool =
  # 4 bytes for Topic plus 1 byte for 0x prefix
  result = value.isValidHexData(10)

const
  SInvalidData = "Invalid hex data format for Ethereum"

proc validateHexData*(value: string) {.inline.} =
  if unlikely(not value.isValidHexData):
    raise newException(ValueError, SInvalidData & ": " & value)

# Initialisation

proc hexDataStr*(value: string): HexDataStr {.inline.} =
  value.validateHexData
  result = value.HexDataStr

# Converters for use in RPC

import json
from json_rpc/rpcserver import expect

proc `%`*(value: HexStrings): JsonNode =
  result = %(value.string)

# Overloads to support expected representation of hex data

proc `%`*(value: Hash256): JsonNode =
  #result = %("0x" & $value) # More clean but no lowercase :(
  result = %("0x" & value.data.toHex)

proc `%`*(value: UInt256): JsonNode =
  result = %("0x" & value.toString(16))

proc `%`*(value: PublicKey): JsonNode =
  result = %("0x04" & $value)

proc `%`*(value: PrivateKey): JsonNode =
  result = %("0x" & $value)

proc `%`*(value: SymKey): JsonNode =
  result = %("0x" & value.toHex)

proc `%`*(value: waku_protocol.Topic): JsonNode =
  result = %("0x" & value.toHex)

proc `%`*(value: seq[byte]): JsonNode =
  if value.len > 0:
    result = %("0x" & value.toHex)
  else:
    result = newJArray()

# Helpers for the fromJson procs

proc toPublicKey*(key: string): PublicKey {.inline.} =
  result = PublicKey.fromHex(key[4 .. ^1]).tryGet()

proc toPrivateKey*(key: string): PrivateKey {.inline.} =
  result = PrivateKey.fromHex(key[2 .. ^1]).tryGet()

proc toSymKey*(key: string): SymKey {.inline.} =
  hexToByteArray(key[2 .. ^1], result)

proc toTopic*(topic: string): waku_protocol.Topic {.inline.} =
  hexToByteArray(topic[2 .. ^1], result)

# Marshalling from JSON to Nim types that includes format checking

func invalidMsg(name: string): string = "When marshalling from JSON, parameter \"" & name & "\" is not valid"

proc fromJson*(n: JsonNode, argName: string, result: var HexDataStr) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHexData:
    raise newException(ValueError, invalidMsg(argName) & " as Ethereum data \"" & hexStr & "\"")
  result = hexStr.hexDataStr

proc fromJson*(n: JsonNode, argName: string, result: var Identifier) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidIdentifier:
    raise newException(ValueError, invalidMsg(argName) & " as a identifier \"" & hexStr & "\"")
  result = hexStr.Identifier

proc fromJson*(n: JsonNode, argName: string, result: var UInt256) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not (hexStr.len <= 66 and hexStr.isValidHexQuantity):
    raise newException(ValueError, invalidMsg(argName) & " as a UInt256 \"" & hexStr & "\"")
  result = readUintBE[256](hexToPaddedByteArray[32](hexStr))

proc fromJson*(n: JsonNode, argName: string, result: var PublicKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidPublicKey:
    raise newException(ValueError, invalidMsg(argName) & " as a public key \"" & hexStr & "\"")
  result = hexStr.toPublicKey

proc fromJson*(n: JsonNode, argName: string, result: var PrivateKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidPrivateKey:
    raise newException(ValueError, invalidMsg(argName) & " as a private key \"" & hexStr & "\"")
  result = hexStr.toPrivateKey

proc fromJson*(n: JsonNode, argName: string, result: var SymKey) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidSymKey:
    raise newException(ValueError, invalidMsg(argName) & " as a symmetric key \"" & hexStr & "\"")
  result = toSymKey(hexStr)

proc fromJson*(n: JsonNode, argName: string, result: var waku_protocol.Topic) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidTopic:
    raise newException(ValueError, invalidMsg(argName) & " as a topic \"" & hexStr & "\"")
  result = toTopic(hexStr)

# Following procs currently required only for testing, the `createRpcSigs` macro
# requires it as it will convert the JSON results back to the original Nim
# types, but it needs the `fromJson` calls for those specific Nim types to do so

proc fromJson*(n: JsonNode, argName: string, result: var Hash256) =
  n.kind.expect(JString, argName)
  let hexStr = n.getStr()
  if not hexStr.isValidHash256:
    raise newException(ValueError, invalidMsg(argName) & " as a Hash256 \"" & hexStr & "\"")
  hexToByteArray(hexStr, result.data)
