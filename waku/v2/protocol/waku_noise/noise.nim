## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[oids, strformat, options, math, tables]
import chronos
import chronicles
import bearssl
import strutils
import stew/[endians2, byteutils]
import nimcrypto/[utils, sha2, hmac]

import libp2p/stream/[connection, streamseq]
import libp2p/peerid
import libp2p/peerinfo
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519, hkdf]
import libp2p/protocols/secure/secure


when defined(libp2p_dump):
  import libp2p/debugutils

logScope:
  topics = "nim-waku noise"

const
  # Empty is a special value which indicates k has not yet been initialized.
  EmptyKey = default(ChaChaPolyKey)
  NonceMax = uint64.high - 1 # max is reserved
  NoiseSize = 32
  MaxPlainSize = int(uint16.high - NoiseSize - ChaChaPolyTag.len)

  HandshakeTimeout = 1.minutes

type
  KeyPair* = object
    privateKey: Curve25519Key
    publicKey: Curve25519Key

  NoisePublicKey* = object
    flag: uint8
    pk: seq[byte]

  ChaChaPolyCiphertext* = object
    data: seq[byte]
    tag: ChaChaPolyTag

  ChaChaPolyCipherState* = object
    k*: ChaChaPolyKey
    nonce*: ChaChaPolyNonce
    ad*: seq[byte]

  #Noise Handshakes

  NoiseTokens* = enum
    T_e = "e"
    T_s = "s"
    T_es = "es"
    T_ee = "ee"
    T_se = "se"
    T_ss = "se"
    T_psk = "psk"
    T_none = ""

  MessageDirection* = enum
    D_r = "->"
    D_l = "<-"
    D_none = ""

  HandshakePattern* = object
    name*: string
    pre_message_patterns*: seq[(MessageDirection, seq[NoiseTokens])]
    message_patterns*: seq[(MessageDirection, seq[NoiseTokens])]

  #Noise states

  # https://noiseprotocol.org/noise.html#the-cipherstate-object
  CipherState* = object
    k: ChaChaPolyKey
    n: uint64

  # https://noiseprotocol.org/noise.html#the-symmetricstate-object
  SymmetricState* = object
    cs: CipherState
    ck: ChaChaPolyKey
    h: MDigest[256]

  # https://noiseprotocol.org/noise.html#the-handshakestate-object
  HandshakeState = object
    s: KeyPair
    e: KeyPair
    rs: Curve25519Key
    re: Curve25519Key
    ss: SymmetricState
    initiator: bool
    handshake_pattern: HandshakePattern
    msg_pattern_idx: uint8
    psk: seq[byte]

  HandshakeResult = object
    cs1: CipherState
    cs2: CipherState
    rs: Curve25519Key
    h: MDigest[256] #The handshake state for channel binding

  NoiseState* = object
    hs: HandshakeState
    hr: HandshakeResult

  Noise* = ref object of Secure
    rng: ref BrHmacDrbgContext
    staticKeyPair: KeyPair
    commonPrologue: seq[byte]
    outgoing: bool


  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseOversizedPayloadError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError # drop connection on purpose
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError

 
#Supported Noise Handshake Patterns
const
  EmptyMessagePattern = @[(D_none, @[T_none])]

  NoiseHandshakePatterns*  = {

    "K1K1":   HandshakePattern(name: "Noise_K1K1_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: @[(D_r, @[T_s]),
                                                       (D_l, @[T_s])],
                               message_patterns:     @[(D_r, @[T_e]),
                                                       (D_l, @[T_e, T_ee, T_es]),
                                                       (D_r, @[T_se])]
                               ),

    "XK1":    HandshakePattern(name: "Noise_XK1_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: @[(D_l, @[T_s])], 
                               message_patterns:     @[(D_r, @[T_e]),
                                                       (D_l, @[T_e, T_ee, T_es]),
                                                       (D_r, @[T_s, T_se])]
                              ),

    "XX":     HandshakePattern(name: "Noise_XX_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: EmptyMessagePattern, 
                               message_patterns:     @[(D_r, @[T_e]),
                                                       (D_l, @[T_e, T_ee, T_s, T_es]),
                                                       (D_r, @[T_s, T_se])]
                              ),

    "XXpsk0": HandshakePattern(name: "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: EmptyMessagePattern, 
                               message_patterns:     @[(D_r, @[T_psk, T_e]),
                                                       (D_l, @[T_e, T_ee, T_s, T_es]),
                                                       (D_r, @[T_s, T_se])]
                              ),

    "test":   HandshakePattern(name: "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: EmptyMessagePattern, 
                               message_patterns:     @[(D_r, @[T_e, T_s, T_psk]),
                                                       (D_l, @[T_e, T_ee, T_s, T_es]),
                                                       (D_r, @[T_s, T_se])]
                              ),
    }.toTable()

  PayloadV2ProtocolIDs*  = {
    "Noise_K1K1_25519_ChaChaPoly_SHA256":   1.uint8,
    "Noise_XK1_25519_ChaChaPoly_SHA256":    2.uint8,
    "Noise_XX_25519_ChaChaPoly_SHA256":     3.uint8,
    "Noise_XXpsk0_25519_ChaChaPoly_SHA256": 4.uint8
    }.toTable()


#Utility for printing Handshake Patterns

proc print*(self: HandshakePattern) 
   {.raises: [IOError].}=
  try:
    if self.name != "":
      echo self.name, ":"
    #We iterate over pre message patterns, if any
    if self.pre_message_patterns != EmptyMessagePattern:
      for pattern in self.pre_message_patterns:
          stdout.write "  ", pattern[0]
          var first = true
          for token in pattern[1]:
            if first:
              stdout.write " ", token
              first = false        
            else:
              stdout.write ", ", token
          stdout.write "\n"          
          stdout.flushFile()
      stdout.write "    ...\n"
      stdout.flushFile()
    #We iterate over message patterns
    for pattern in self.message_patterns:
      stdout.write "  ", pattern[0]
      var first = true
      for token in pattern[1]:
        if first:
          stdout.write " ", token
          first = false        
        else:
          stdout.write ", ", token
      stdout.write "\n"
      stdout.flushFile()
  except:
    echo "HandshakePattern malformed"

# Utility

proc genKeyPair*(rng: var BrHmacDrbgContext): KeyPair =
  result.privateKey = Curve25519Key.random(rng)
  result.publicKey = result.privateKey.public()

proc hashProtocol(name: string): MDigest[256] =
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).

  if name.len <= 32:
    result.data[0..name.high] = name.toBytes
  else:
    result = sha256.digest(name)

proc dh(priv: Curve25519Key, pub: Curve25519Key): Curve25519Key =
  result = pub
  Curve25519.mul(result, priv)

# Cipherstate

proc hasKey(cs: CipherState): bool =
  cs.k != EmptyKey

proc encrypt(
    state: var CipherState,
    data: var openArray[byte],
    ad: openArray[byte]): ChaChaPolyTag
    {.noinit, raises: [Defect, NoiseNonceMaxError].} =

  var nonce: ChaChaPolyNonce
  nonce[4..<12] = toBytesLE(state.n)

  ChaChaPoly.encrypt(state.k, nonce, result, data, ad)

  inc state.n
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

proc encryptWithAd(state: var CipherState, ad, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =
  result = newSeqOfCap[byte](data.len + sizeof(ChaChaPolyTag))
  result.add(data)

  let tag = encrypt(state, result, ad)

  result.add(tag)

  trace "encryptWithAd",
    tag = byteutils.toHex(tag), data = result.shortLog, nonce = state.n - 1

proc decryptWithAd(state: var CipherState, ad, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  var
    tagIn = data.toOpenArray(data.len - ChaChaPolyTag.len, data.high).intoChaChaPolyTag
    tagOut: ChaChaPolyTag
    nonce: ChaChaPolyNonce
  nonce[4..<12] = toBytesLE(state.n)
  result = data[0..(data.high - ChaChaPolyTag.len)]
  ChaChaPoly.decrypt(state.k, nonce, tagOut, result, ad)
  trace "decryptWithAd", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.n
  if tagIn != tagOut:
    debug "decryptWithAd failed", data = shortLog(data)
    raise newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")
  inc state.n
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

# Symmetricstate

proc init*(_: type[SymmetricState], hs_pattern: HandshakePattern): SymmetricState =
  result.h = hs_pattern.name.hashProtocol
  result.ck = result.h.data.intoChaChaPolyKey
  result.cs = CipherState(k: EmptyKey)

proc mixKey(ss: var SymmetricState, ikm: ChaChaPolyKey) =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.cs = CipherState(k: temp_keys[1])
  trace "mixKey", key = ss.cs.k.shortLog

proc mixHash(ss: var SymmetricState, data: openArray[byte]) =
  var ctx: sha256
  ctx.init()
  ctx.update(ss.h.data)
  ctx.update(data)
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data.shortLog

# We might use this for other handshake patterns/tokens
proc mixKeyAndHash(ss: var SymmetricState, ikm: openArray[byte]) {.used.} =
  var
    temp_keys: array[3, ChaChaPolyKey]
  sha256.hkdf(ss.ck, ikm, [], temp_keys)
  ss.ck = temp_keys[0]
  ss.mixHash(temp_keys[1])
  ss.cs = CipherState(k: temp_keys[2])

proc encryptAndHash(ss: var SymmetricState, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey:
    result = ss.cs.encryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(result)

proc decryptAndHash(ss: var SymmetricState, data: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  # according to spec if key is empty leave plaintext
  if ss.cs.hasKey and data.len > ChaChaPolyTag.len:
    result = ss.cs.decryptWithAd(ss.h.data, data)
  else:
    result = @data
  ss.mixHash(data)

proc split(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  var
    temp_keys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], temp_keys)
  return (CipherState(k: temp_keys[0]), CipherState(k: temp_keys[1]))


# Handshake state

proc init*(_: type[HandshakeState], hs_pattern: HandshakePattern, psk: seq[byte] = @[]): HandshakeState =
  # set to true only if startHandshake is called over the handshake state
  result.initiator = false
  result.handshake_pattern = hs_pattern
  result.psk = psk
  result.ss = SymmetricState.init(hs_pattern)

template write_e: untyped =
  trace "noise write e"
  # Sets e (which must be empty) to GENERATE_KEYPAIR(). Appends e.public_key to the buffer. Calls MixHash(e.public_key).
  hs.e = genKeyPair(p.rng[])
  msg.add hs.e.publicKey
  hs.ss.mixHash(hs.e.publicKey)

template write_s: untyped =
  trace "noise write s"
  # Appends EncryptAndHash(s.public_key) to the buffer.
  msg.add hs.ss.encryptAndHash(hs.s.publicKey)

template dh_ee: untyped =
  trace "noise dh ee"
  # Calls MixKey(DH(e, re)).
  hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

template dh_es: untyped =
  trace "noise dh es"
  # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
  else:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

template dh_se: untyped =
  trace "noise dh se"
  # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
  when initiator:
    hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
  else:
    hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

# might be used for other token/handshakes
template dh_ss: untyped {.used.} =
  trace "noise dh ss"
  # Calls MixKey(DH(s, rs)).
  hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

template read_e: untyped =
  trace "noise read e", size = msg.len

  if msg.len < Curve25519Key.len:
    raise newException(NoiseHandshakeError, "Noise E, expected more data")

  # Sets re (which must be empty) to the next DHLEN bytes from the message. Calls MixHash(re.public_key).
  hs.re[0..Curve25519Key.high] = msg.toOpenArray(0, Curve25519Key.high)
  msg.consume(Curve25519Key.len)
  hs.ss.mixHash(hs.re)

template read_s: untyped =
  trace "noise read s", size = msg.len
  # Sets temp to the next DHLEN + 16 bytes of the message if HasKey() == True, or to the next DHLEN bytes otherwise.
  # Sets rs (which must be empty) to DecryptAndHash(temp).
  let
    rsLen =
      if hs.ss.cs.hasKey:
        if msg.len < Curve25519Key.len + ChaChaPolyTag.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        Curve25519Key.len + ChaChaPolyTag.len
      else:
        if msg.len < Curve25519Key.len:
          raise newException(NoiseHandshakeError, "Noise S, expected more data")
        Curve25519Key.len
  hs.rs[0..Curve25519Key.high] =
    hs.ss.decryptAndHash(msg.toOpenArray(0, rsLen - 1))

  msg.consume(rsLen)




#################################################################



# Vanilla ChaChaPoly encryption
proc encrypt*(
    state: ChaChaPolyCipherState,
    plaintext: openArray[byte]): ChaChaPolyCiphertext
    {.noinit, raises: [Defect].} =
  #TODO: add padding
  result.data.add plaintext
  ChaChaPoly.encrypt(state.k, state.nonce, result.tag, result.data, state.ad)

proc decrypt*(
    state: ChaChaPolyCipherState, 
    ciphertext: ChaChaPolyCiphertext): seq[byte]
    {.raises: [Defect, NoiseDecryptTagError].} =
  var
    tagIn = ciphertext.tag
    tagOut: ChaChaPolyTag
  result = ciphertext.data
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, result, state.ad)
  #TODO: add unpadding
  trace "decrypt", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.nonce
  if tagIn != tagOut:
    debug "decrypt failed", result = shortLog(result)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")


proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  brHmacDrbgGenerate(rng, result.k)
  brHmacDrbgGenerate(rng, result.nonce)
  result.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, result.ad)





# Public keys serializations/encryption

proc `==`(k1, k2: NoisePublicKey): bool =
  result = (k1.flag == k2.flag) and (k1.pk == k2.pk)
  

proc keyPairToNoisePublicKey*(keyPair: KeyPair): NoisePublicKey =
  result.flag = 0
  result.pk = getBytes(keyPair.publicKey)


proc genNoisePublicKey*(rng: var BrHmacDrbgContext): NoisePublicKey =
  let keyPair: KeyPair = genKeyPair(rng)
  result.flag = 0
  result.pk = getBytes(keyPair.publicKey)

proc serializeNoisePublicKey*(noisePublicKey: NoisePublicKey): seq[byte] =
  result.add noisePublicKey.flag
  result.add noisePublicKey.pk

#TODO: strip pk_auth if pk not encrypted
proc intoNoisePublicKey*(serializedNoisePublicKey: seq[byte]): NoisePublicKey =
  result.flag = serializedNoisePublicKey[0]
  assert result.flag == 0 or result.flag == 1
  result.pk = serializedNoisePublicKey[1..<serializedNoisePublicKey.len]

# Public keys encryption/decryption

proc encryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseNonceMaxError].} =
  if cs.k != EmptyKey and noisePublicKey.flag == 0:
    let enc_pk = encrypt(cs, noisePublicKey.pk)
    result.flag = 1
    result.pk = enc_pk.data
    result.pk.add enc_pk.tag
  else:
    result = noisePublicKey


proc decryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseDecryptTagError].} =
  if cs.k != EmptyKey and noisePublicKey.flag == 1:
    #let ciphertext = ChaChaPolyCiphertext(data: noisePublicKey.pk, tag: noisePublicKey.pk_auth)
    let pk_len = noisePublicKey.pk.len - ChaChaPolyTag.len
    let pk = noisePublicKey.pk[0..<pk_len]
    let pk_auth = intoChaChaPolyTag(noisePublicKey.pk[pk_len..<pk_len+ChaChaPolyTag.len])
    let ciphertext = ChaChaPolyCiphertext(data: pk, tag: pk_auth) 
    result.pk = decrypt(cs, ciphertext)
    result.flag = 0
  else:
    if cs.k == EmptyKey:
      debug "No key in cipher state."
    if noisePublicKey.flag == 0:
      debug "Public key is not encrypted."
    debug "Public key is left unchanged"
    result = noisePublicKey




# Payload functions
type
  PayloadV2* = object
    protocol_id: uint8
    handshake_message: seq[NoisePublicKey]
    transport_message: seq[byte]
    #transport_message_auth: ChaChaPolyTag


proc `==`(p1, p2: PayloadV2): bool =
  result =  (p1.protocol_id == p2.protocol_id) and 
            (p1.handshake_message == p2.handshake_message) and 
            (p1.transport_message == p2.transport_message) #and 
            #(p1.transport_message_auth == p2.transport_message_auth)
  


proc randomPayloadV2*(rng: var BrHmacDrbgContext): PayloadV2 =
  var protocol_id = newSeq[byte](1)
  brHmacDrbgGenerate(rng, protocol_id)
  result.protocol_id = protocol_id[0].uint8
  result.handshake_message = @[genNoisePublicKey(rng), genNoisePublicKey(rng), genNoisePublicKey(rng)]
  result.transport_message = newSeq[byte](128)
  brHmacDrbgGenerate(rng, result.transport_message)


proc encodeV2*(self: PayloadV2): Option[seq[byte]] =

  #We collect public keys contained in the handshake message
  var
    ser_handshake_message_len: int = 0
    ser_handshake_message = newSeqOfCap[byte](256)
    ser_pk: seq[byte]
  for pk in self.handshake_message:
    ser_pk = serializeNoisePublicKey(pk)
    ser_handshake_message_len +=  ser_pk.len
    ser_handshake_message.add ser_pk


  #RFC: handshake-message-len is 1 byte
  if ser_handshake_message_len > 256:
    debug "Payload malformed: too many public keys contained in the handshake message"
    return none(seq[byte])

  let transport_message_len = self.transport_message.len
  #let transport_message_len_len = ceil(log(transport_message_len, 8)).int

  var payload = newSeqOfCap[byte](1 + #self.protocol_id.len +              
                                  1 + #ser_handshake_message_len 
                                  ser_handshake_message_len +        
                                  8 + #transport_message_len
                                  transport_message_len #+ #self.transport_message
                                  )#self.transport_message_auth.len)
  
  
  payload.add self.protocol_id.byte
  payload.add ser_handshake_message_len.byte
  payload.add ser_handshake_message
  payload.add toBytesLE(transport_message_len.uint64)
  payload.add self.transport_message
  #payload.add self.transport_message_auth

  return some(payload)



#Decode Noise handshake payload
proc decodeV2*(payload: seq[byte]): Option[PayloadV2] =
  var res: PayloadV2

  var i: uint64 = 0
  res.protocol_id = payload[i].uint8
  i+=1

  var handshake_message_len = payload[i].uint64
  i+=1

  var handshake_message: seq[NoisePublicKey]

  var 
    flag: byte
    pk_len: uint64
    written: uint64 = 0

  while written != handshake_message_len:
    #Note that flag can be used to add support to multiple Elliptic Curve arithmetics..
    flag = payload[i]
    if flag == 0:
      pk_len = 1 + Curve25519Key.len
      handshake_message.add intoNoisePublicKey(payload[i..<i+pk_len])
      i += pk_len
      written += pk_len
    if flag == 1:
      pk_len = 1 + Curve25519Key.len + ChaChaPolyTag.len
      handshake_message.add intoNoisePublicKey(payload[i..<i+pk_len])
      i += pk_len
      written += pk_len

  res.handshake_message = handshake_message

  let transport_message_len = fromBytesLE(uint64, payload[i..(i+8-1)])
  i+=8

  res.transport_message = payload[i..i+transport_message_len-1]
  i+=transport_message_len

  #res.transport_message_auth = intoChaChaPolyTag(payload[i..i+ChaChaPolyTag.len-1])

  return some(res)











##### Handshake procedures



proc initialize*(hs_pattern: HandshakePattern, staticKey: KeyPair, prologue: seq[byte] = @[]): HandshakeState =
  var hs = HandshakeState.init(hs_pattern)
  hs.ss.mixHash(prologue)
  hs.s = staticKey
  return hs


proc processMessagePatternTokens*(rng: var BrHmacDrbgContext, hs: var HandshakeState, tokens: seq[NoiseTokens], transport_message: seq[byte]): Result[PayloadV2, cstring]
  {.raises: [Defect, NoiseMalformedHandshake, NoiseNonceMaxError].} =

  #We initialize an empty payload v2, with proper protocol ID (if supported)
  var p: PayloadV2
  try:
    p.protocol_id = PayloadV2ProtocolIDs[hs.handshake_pattern.name]
  except:
    raise newException(NoiseMalformedHandshake, "Handshake Pattern not supported")
    

  #TODO: Process direction here, and if init direction agree then is a write, otherwise a read
  
  #We process each message pattern token
  for token in tokens:
    case token
    of T_e:

      trace "noise write e"

      #We generate a new ephemeral keypair
      hs.e = genKeyPair(rng)

      #We update the state
      hs.ss.mixHash(hs.e.publicKey)
      # Noise specification: section 9.2
      # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results 
      # in a call to MixHash(e.public_key). 
      # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
      if "psk" in hs.handshake_pattern.name:
        hs.ss.mixKey(hs.e.publicKey)

      #We add the ephemeral public key to the Waku payload
      p.handshake_message.add keyPairToNoisePublicKey(hs.e)

    of T_s:

      trace "noise write s"

      if hs.s == default(KeyPair):
        raise newException(NoiseMalformedHandshake, "Static key not set")

      #We update the state
      let enc_s = hs.ss.encryptAndHash(hs.s.publicKey)

      #We add the static public key to the Waku payload
      #Note that enc_s = (Enc(s) || tag) if encryption key is set otherwise enc_s = s.
      #We distinguish these two cases by checking length of encryption
      if enc_s.len > Curve25519Key.len:
        p.handshake_message.add NoisePublicKey(flag: 1, pk: enc_s)
      else:
        p.handshake_message.add NoisePublicKey(flag: 0, pk: enc_s)

    of T_psk:

      trace "noise psk"

      #Calls MixKeyAndHash(psk)
      hs.ss.mixKeyAndHash(hs.psk)

    of T_ee:

      trace "noise dh ee"

      if hs.e == default(KeyPair) or hs.re == default(Curve25519Key):
        raise newException(NoiseMalformedHandshake, "Local or remote ephemeral key not set")

      # Calls MixKey(DH(e, re)).
      hs.ss.mixKey(dh(hs.e.privateKey, hs.re))

    of T_es:

      trace "noise dh es"

      if hs.e == default(KeyPair) or hs.rs == default(Curve25519Key):
        raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")


      # Calls MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
      when hs.initiator:
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
      else:
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

    of T_se:

      trace "noise dh se"

      if hs.s == default(KeyPair) or hs.re == default(Curve25519Key):
        raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")

      # Calls MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
      when hs.initiator:
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
      else:
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

    of T_ss:

      trace "noise dh ss"

      if hs.s == default(KeyPair) or hs.rs == default(Curve25519Key):
        raise newException(NoiseMalformedHandshake, "Local or remote static key not set")

      # Calls MixKey(DH(s, rs)).
      hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

    else:
      raise newException(NoiseMalformedHandshake, "Invalid token in message pattern")

  #We encrypt the transport_message, if any
  if transport_message.len > 0:
    p.transport_message.add hs.ss.encryptAndHash(transport_message)

  return ok(p)


proc startHandshake*(rng: var BrHmacDrbgContext, hs: var HandshakeState, transport_message: seq[byte] = @[]): Result[PayloadV2, cstring]
  {.raises: [Defect, NoiseMalformedHandshake, NoiseNonceMaxError].} =

  #We are the initiator of the handshake
  hs.initiator = true
  
  ### PRE-MESSAGE PATTERN
  
  #TODO process here pre-message pattern

  ### MESSAGE PATTERN

  #We process the first message pattern
  hs.msg_pattern_idx = 0

  #We retrieve the relevant handshake information
  let
    message_pattern = hs.handshake_pattern.message_patterns[hs.msg_pattern_idx]
    direction = message_pattern[0]
    tokens = message_pattern[1]

  #We start a handshake only if the first handshake pattern direction goes from alice to Bob
  if direction == D_r:

    var p = processMessagePatternTokens(rng, hs, tokens, transport_message)

    #We increase the handshake state message pattern index
    hs.msg_pattern_idx += 1

    #echo p

    return ok(p.get())

  else:
    raise newException(NoiseMalformedHandshake, "First handshake message doesn't come from initiator")




#We return a tuple with the optional handshake payload and the payload for continuing the handshake 
proc continueHandshake*(rng: var BrHmacDrbgContext, hs: var HandshakeState, transport_message: seq[byte] = @[], waku_payload: PayloadV2): Result[(seq[byte], PayloadV2), cstring]
  {.raises: [Defect, NoiseMalformedHandshake, NoiseNonceMaxError].} =

  #TODO process here pre-message pattern
  if hs.msg_pattern_idx == 0:

    ### PRE-MESSAGE PATTERN
    
  

  ### MESSAGE PATTERN

  #We retrieve the relevant handshake information
  let
    message_pattern = hs.handshake_pattern.message_patterns[hs.msg_pattern_idx]
    direction = message_pattern[0]
    tokens = message_pattern[1]

  #We start a handshake only if the first handshake pattern direction goes from alice to Bob
  if direction == D_r:

    var p = processMessagePatternTokens(rng, hs, tokens, transport_message)

    #We increase the handshake state message pattern index
    hs.msg_pattern_idx += 1

    return ok((@[],p.get()))

  else:
    raise newException(NoiseMalformedHandshake, "First handshake message doesn't come from initiator")