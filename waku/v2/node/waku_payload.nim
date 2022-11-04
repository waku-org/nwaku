when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/options,
  eth/keys,
  ../../whisper/whisper_types,
  ../protocol/waku_message,
  ../protocol/waku_noise/noise_types,
  ../protocol/waku_noise/noise_utils

export whisper_types, keys, options

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

  # NOTE: Currently only used here, if we start using it elsewhere pull it out.
  WakuResult*[T] = Result[T, cstring]


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
    else:
      discard
  else:
    return err("Unsupported WakuMessage version")

# TODO: same story as for `decodedPayload`, but then regarding the `Payload`
# object.
proc encode*(payload: Payload, version: uint32, rng: var HmacDrbgContext):
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


# Decodes a WakuMessage to a PayloadV2
# Currently, this is just a wrapper over deserializePayloadV2 and encryption/decryption is done on top (no KeyInfo)
proc decodePayloadV2*(message: WakuMessage): WakuResult[PayloadV2] 
  {.raises: [Defect, NoiseMalformedHandshake, NoisePublicKeyError].} =
  # We check message version (only 2 is supported in this proc)
  case message.version
  of 2:
    # We attempt to decode the WakuMessage payload
    let deserializedPayload2 = deserializePayloadV2(message.payload)
    if deserializedPayload2.isOk():
      return ok(deserializedPayload2.get())
    else:
      return err("Failed to decode WakuMessage")
  else:
    return err("Wrong message version while decoding payload")


# Encodes a PayloadV2 to a WakuMessage
# Currently, this is just a wrapper over serializePayloadV2 and encryption/decryption is done on top (no KeyInfo)
proc encodePayloadV2*(payload2: PayloadV2, contentTopic: ContentTopic = default(ContentTopic)): WakuResult[WakuMessage] 
  {.raises: [Defect, NoiseMalformedHandshake, NoisePublicKeyError].} =

  # We attempt to encode the PayloadV2
  let serializedPayload2 = serializePayloadV2(payload2)
  if not serializedPayload2.isOk():
    return err("Failed to encode PayloadV2")

  # If successful, we create and return a WakuMessage 
  let msg = WakuMessage(payload: serializedPayload2.get(), version: 2, contentTopic: contentTopic)
  
  return ok(msg)