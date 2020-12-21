import
  std/options,
  eth/keys,
  eth/p2p/rlpx_protocols/whisper/whisper_types,
  ../waku_types

export whisper_types, waku_types, keys, options

type
  KeyKind* = enum
    Symmetric
    Asymmetric
    None

  KeyInfo* = object
    case kind*: KeyKind
    of Symmetric:
      symKey*: SymKey
    of Asymmetric:
      privKey*: PrivateKey
    of None:
      discard

# TODO:
# - This is using `DecodedPayload` from Waku v1 / Whisper and could be altered
# by making that a case object also, e.g. useful for the version 0, but
# especially in the future if there would be yet another version.
# - Also reworking that API to use Result instead of Option could make this
# cleaner.
# - For now this `KeyInfo` is a bit silly also, but perhaps with v2 or
# adjustments to Waku v1 encoding, it can be better.
proc decodePayload*(message: WakuMessage, keyInfo: KeyInfo):
    WakuResult[DecodedPayload] =
  case message.version
  of 0:
    return ok(DecodedPayload(payload:message.payload))
  of 1:
    case keyInfo.kind
    of Symmetric:
      let decoded = message.payload.decode(none[PrivateKey](),
        some(keyInfo.symKey))
      if decoded.isSome():
        return ok(decoded.get())
      else:
        return err("Couldn't decrypt using symmetric key")
    of Asymmetric:
      let decoded = message.payload.decode(some(keyInfo.privkey),
        none[SymKey]())
      if decoded.isSome():
        return ok(decoded.get())
      else:
        return err("Couldn't decrypt using asymmetric key")
    of None:
      discard
  else:
    return err("Unsupported WakuMessage version")

# TODO: same story as for `decodedPayload`, but then regarding the `Payload`
# object.
proc encode*(payload: Payload, version: uint32, rng: var BrHmacDrbgContext):
    WakuResult[seq[byte]] =
  case version
  of 0:
    # This is rather silly
    return ok(payload.payload)
  of 1:
    let encoded = encode(rng, payload)
    if encoded.isSome():
      return ok(encoded.get())
    else:
      return err("Couldn't encode the payload")
  else:
    return err("Unsupported WakuMessage version")
