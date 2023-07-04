import
  stew/[results, byteutils],
  eth/keys,
  json,
  json_rpc/rpcserver
import
  ../../waku/whisper/whisper_types,
  ../../waku/common/hexstrings,
  ../marshalling,
  ../message

export message


type
  WakuKeyPair* = object
    seckey*: keys.PrivateKey
    pubkey*: keys.PublicKey


## JSON-RPC type marshalling

# SymKey

proc `%`*(value: SymKey): JsonNode =
  %("0x" & value.toHex())

func isValidSymKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  value.isValidHexData(66)

proc toSymKey*(key: string): SymKey {.inline.} =
  hexToByteArray(key[2 .. ^1], result)

proc fromJson*(n: JsonNode, argName: string, value: var SymKey) =
  n.kind.expect(JString, argName)

  let hexStr = n.getStr()
  if not isValidSymKey(hexStr):
    raise newException(ValueError, invalidMsg(argName) & " as a symmetric key \"" & hexStr & "\"")

  value = hexStr.toSymKey()

# PublicKey

proc `%`*(value: PublicKey): JsonNode =
  %("0x04" & $value)

func isValidPublicKey*(value: string): bool =
  # 65 bytes for Public Key plus 1 byte for 0x prefix
  value.isValidHexData(132)

proc toPublicKey*(key: string): PublicKey {.inline.} =
  PublicKey.fromHex(key[4 .. ^1]).tryGet()

proc fromJson*(n: JsonNode, argName: string, value: var PublicKey) =
  n.kind.expect(JString, argName)

  let hexStr = n.getStr()
  if not isValidPublicKey(hexStr):
    raise newException(ValueError, invalidMsg(argName) & " as a public key \"" & hexStr & "\"")

  value = hexStr.toPublicKey()

# PrivateKey

proc `%`*(value: PrivateKey): JsonNode =
  %("0x" & $value)

func isValidPrivateKey*(value: string): bool =
  # 32 bytes for Private Key plus 1 byte for 0x prefix
  value.isValidHexData(66)

proc toPrivateKey*(key: string): PrivateKey {.inline.} =
  PrivateKey.fromHex(key[2 .. ^1]).tryGet()

proc fromJson*(n: JsonNode, argName: string, value: var PrivateKey) =
  n.kind.expect(JString, argName)

  let hexStr = n.getStr()
  if not isValidPrivateKey(hexStr):
    raise newException(ValueError, invalidMsg(argName) & " as a private key \"" & hexStr & "\"")

  value = hexStr.toPrivateKey()
