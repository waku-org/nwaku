# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially readapted from noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [Defect].}

import std/[oids, options, math, tables]
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


type
  KeyPair* = object
    privateKey: Curve25519Key
    publicKey*: Curve25519Key

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

  # Waku Payload

  PayloadV2* = object
    protocol_id: uint8
    handshake_message: seq[NoisePublicKey]
    transport_message: seq[byte]

  #Noise Handshakes

  NoiseTokens* = enum
    T_e = "e"
    T_s = "s"
    T_es = "es"
    T_ee = "ee"
    T_se = "se"
    T_ss = "se"
    T_psk = "psk"

  MessageDirection* = enum
    D_r = "->"
    D_l = "<-"

  PreMessagePattern* = object
    direction: MessageDirection
    tokens: seq[NoiseTokens]

  MessagePattern* = object
    direction: MessageDirection
    tokens: seq[NoiseTokens]

  HandshakePattern* = object
    name*: string
    pre_message_patterns*: seq[PreMessagePattern]
    message_patterns*: seq[MessagePattern]

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

  HandshakeStepResult* = object
    payload2*: PayloadV2
    transport_message*: seq[byte]

  HandshakeResult* = object
    cs_write: CipherState
    cs_read: CipherState
    rs: Curve25519Key
    h: MDigest[256] #The handshake state, useful for channel binding

  NoiseState* = object
    hs: HandshakeState
    hr: HandshakeResult

  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError


# Supported Noise Handshake Patterns
const
  EmptyPreMessagePattern: seq[PreMessagePattern] = @[]

  NoiseHandshakePatterns*  = {
    "K1K1":   HandshakePattern(name: "Noise_K1K1_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: @[PreMessagePattern(direction: D_r, tokens: @[T_s]),
                                                       PreMessagePattern(direction: D_l, tokens: @[T_s])],
                               message_patterns:     @[   MessagePattern(direction: D_r, tokens: @[T_e]),
                                                          MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
                                                          MessagePattern(direction: D_r, tokens: @[T_se])]
                               ),

    "XK1":    HandshakePattern(name: "Noise_XK1_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: @[PreMessagePattern(direction: D_l, tokens: @[T_s])], 
                               message_patterns:     @[   MessagePattern(direction: D_r, tokens: @[T_e]),
                                                          MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
                                                          MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              ),

    "XX":     HandshakePattern(name: "Noise_XX_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: EmptyPreMessagePattern, 
                               message_patterns:     @[MessagePattern(direction: D_r, tokens: @[T_e]),
                                                       MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
                                                       MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              ),

    "XXpsk0": HandshakePattern(name: "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
                               pre_message_patterns: EmptyPreMessagePattern, 
                               message_patterns:     @[MessagePattern(direction: D_r, tokens: @[T_psk, T_e]),
                                                       MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
                                                       MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              )
    }.toTable()


  PayloadV2ProtocolIDs*  = {

    "":                                      0.uint8,
    "Noise_K1K1_25519_ChaChaPoly_SHA256":   10.uint8,
    "Noise_XK1_25519_ChaChaPoly_SHA256":    11.uint8,
    "Noise_XX_25519_ChaChaPoly_SHA256":     12.uint8,
    "Noise_XXpsk0_25519_ChaChaPoly_SHA256": 13.uint8,
    "ChaChaPoly":                           30.uint8

    }.toTable()


# Utility

#Printing Handshake Patterns
proc print*(self: HandshakePattern) 
   {.raises: [IOError, NoiseMalformedHandshake].}=
  try:
    if self.name != "":
      echo self.name, ":"
    #We iterate over pre message patterns, if any
    if self.pre_message_patterns != EmptyPreMessagePattern:
      for pattern in self.pre_message_patterns:
          stdout.write "  ", pattern.direction
          var first = true
          for token in pattern.tokens:
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
      stdout.write "  ", pattern.direction
      var first = true
      for token in pattern.tokens:
        if first:
          stdout.write " ", token
          first = false        
        else:
          stdout.write ", ", token
      stdout.write "\n"
      stdout.flushFile()
  except:
    raise newException(NoiseMalformedHandshake, "HandshakePattern malformed")


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

proc randomSeqByte*(rng: var BrHmacDrbgContext, size: uint32): seq[byte] =
  result = newSeq[byte](size)
  brHmacDrbgGenerate(rng, result)

#################################################################

# Noise Handshake State Machine

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

proc mixKey(ss: var SymmetricState, ikm: openArray[byte]) =
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

proc init*(_: type[HandshakeState], hs_pattern: HandshakePattern): HandshakeState =
  # set to true only if startHandshake is called over the handshake state
  result.initiator = false
  result.handshake_pattern = hs_pattern
  result.ss = SymmetricState.init(hs_pattern)


#################################################################


# ChaChaPoly encryption
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


#################################################################


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

proc intoNoisePublicKey*(serializedNoisePublicKey: seq[byte]): NoisePublicKey =
  result.flag = serializedNoisePublicKey[0]
  assert result.flag == 0 or result.flag == 1
  result.pk = serializedNoisePublicKey[1..<serializedNoisePublicKey.len]

proc intoNoisePublicKey*(publicKey: Curve25519Key): NoisePublicKey =
  result.flag = 0
  result.pk = getBytes(publicKey)


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



#################################################################


# Payload V2 functions

proc `==`(p1, p2: PayloadV2): bool =
  result =  (p1.protocol_id == p2.protocol_id) and 
            (p1.handshake_message == p2.handshake_message) and 
            (p1.transport_message == p2.transport_message) 
  


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

  var payload = newSeqOfCap[byte](1 + #self.protocol_id.len +              
                                  1 + #ser_handshake_message_len 
                                  ser_handshake_message_len +        
                                  8 + #transport_message_len
                                  transport_message_len #self.transport_message
                                  )
  
  
  payload.add self.protocol_id.byte
  payload.add ser_handshake_message_len.byte
  payload.add ser_handshake_message
  payload.add toBytesLE(transport_message_len.uint64)
  payload.add self.transport_message

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

  return some(res)



#################################################################


##### Handshake Processing (over Waku Payloads V2)

## Utility

# Based on a message handshake direction the if the user is or not the initiator, returns a tuple telling if the user
# should read the handshake message or write it
proc getReadingWritingState(hs: HandshakeState, direction: MessageDirection): (bool, bool) =

  var reading, writing : bool

  if hs.initiator and direction == D_r:
    #I'm Alice and direction is ->
    reading = false
    writing = true
  elif hs.initiator and direction == D_l:
    #I'm Alice and direction is <-
    reading = true
    writing = false
  elif not hs.initiator and direction == D_r:
    #I'm Bob and direction is ->
    reading = true
    writing = false
  elif not hs.initiator and direction == D_l:
    #I'm Bob and direction is <-
    reading = false
    writing = true

  return (reading, writing)


## Procedures to process handshake messages

# Processing of pre-message patterns
proc processPreMessagePatternTokens*(hs: var HandshakeState, in_pre_message_pks: seq[NoisePublicKey] = @[])
  {.raises: [Defect, NoiseMalformedHandshake, NoiseHandshakeError, NoisePublicKeyError].} =

  var 
    # I make a copy of the pre message pattern so that I can easily delete processed PKs without using iterators/counters
    pre_message_pks = in_pre_message_pks
    # Here we store currently processed input pre message public key
    curr_pk : NoisePublicKey

  #We retrieve the pre-message patterns to process, if any
  # If none, there's nothing to do
  if hs.handshake_pattern.pre_message_patterns == EmptyPreMessagePattern:
    return

  #If there are, we iterate each of those
  for message_pattern in hs.handshake_pattern.pre_message_patterns:
    let
      direction = message_pattern.direction
      tokens = message_pattern.tokens
    
    # We get if the user is reading or writing the current pre-message pattern
    var (reading, writing) = getReadingWritingState(hs , direction)
    
  
    # Now the user is reading should be the only option right now
    #We process each message pattern token
    for token in tokens:
      case token
      of T_e:

        if pre_message_pks.len > 0:
          curr_pk = pre_message_pks[0]
        else:
          raise newException(NoiseHandshakeError, "Noise pre-message read e, expected a public key")

        if reading:
          trace "noise pre-message read e"

          # We check if current key is encrypted or not. We assume pre-message public keys are all unencrypted on the user's end
          if curr_pk.flag == 0.uint8:

            # Sets re and calls MixHash(re.public_key).
            hs.re = intoCurve25519Key(curr_pk.pk)
            hs.ss.mixHash(hs.re)

          else:
            raise newException(NoisePublicKeyError, "Noise read e, incorrect encryption flag for pre-message public key")
   
        elif writing:
   
          trace "noise pre-message write e"

          # If writing, it means that the user is sending a public key, 
          # We check that the public part corresponds to the set Keypair and we call MixHash(e.public_key).
          if hs.e.publicKey == intoCurve25519Key(curr_pk.pk):
            hs.ss.mixHash(hs.e.publicKey)
          else:
            raise newException(NoisePublicKeyError, "Noise pre-message e key doesn't correspond to locally set e key pair")

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results 
        # in a call to MixHash(e.public_key). 
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshake_pattern.name:
          hs.ss.mixKey(curr_pk.pk)

        # We delete processed public key 
        pre_message_pks.delete(0)

      of T_s:

        if pre_message_pks.len > 0:
          curr_pk = pre_message_pks[0]
        else:
          raise newException(NoiseHandshakeError, "Noise pre-message read s, expected a public key")

        if reading:
          trace "noise pre-message read s"

          # We check if current key is encrypted or not. We assume pre-message public keys are all unencrypted on the user's end
          if curr_pk.flag == 0.uint8:

            # Sets re and calls MixHash(re.public_key).
            hs.rs = intoCurve25519Key(curr_pk.pk)
            hs.ss.mixHash(hs.rs)

          else:
            raise newException(NoisePublicKeyError, "Noise read s, incorrect encryption flag for pre-message public key")
   
        elif writing:
   
          trace "noise pre-message write s"

          # If writing, it means that the user is sending a public key, 
          # We check that the public part corresponds to the set Keypair and we call MixHash(e.public_key).
          if hs.s.publicKey == intoCurve25519Key(curr_pk.pk):
            hs.ss.mixHash(hs.s.publicKey)
          else:
            raise newException(NoisePublicKeyError, "Noise pre-message s key doesn't correspond to locally set s key pair")

        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results 
        # in a call to MixHash(e.public_key). 
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshake_pattern.name:
          hs.ss.mixKey(curr_pk.pk)

        # We delete processed public key 
        pre_message_pks.delete(0)

      else:

        raise newException(NoiseMalformedHandshake, "Invalid Token for pre-message pattern")


# This procedure encrypts/decrypts the implicit payload attached at the end of every message pattern
proc processMessagePatternPayload(hs: var HandshakeState, transport_message: seq[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =

  #We retrieve current message pattern (direction + tokens) to process
  let direction = hs.handshake_pattern.message_patterns[hs.msg_pattern_idx].direction

  # We get if the user is reading or writing the input handshake message
  var (reading, writing) = getReadingWritingState(hs, direction)

  #We decrypt the transport_message, if any
  if reading:
    result = hs.ss.decryptAndHash(transport_message)
  elif writing:
    result = hs.ss.encryptAndHash(transport_message)


# We process an input handshake message according to the currend handshake state and we return the next handshake step's handshake message
proc processMessagePatternTokens*(rng: var BrHmacDrbgContext, hs: var HandshakeState, input_handshake_message: seq[NoisePublicKey] = @[]): Result[seq[NoisePublicKey], cstring]
  {.raises: [Defect, NoiseHandshakeError, NoiseMalformedHandshake, NoisePublicKeyError, NoiseDecryptTagError, NoiseNonceMaxError].} =

  #We retrieve current message pattern (direction + tokens) to process
  let
    message_pattern = hs.handshake_pattern.message_patterns[hs.msg_pattern_idx]
    direction = message_pattern.direction
    tokens = message_pattern.tokens
    
  # We get if the user is reading or writing the input handshake message
  var (reading, writing) = getReadingWritingState(hs , direction)
  

  # I make a copy of the handshake message so that I can easily delete processed PKs without using iterators/counters
  # (Possibly) non-empty if reading
  var in_handshake_message = input_handshake_message

  # The party's output public keys
  # (Possibly) non-empty if writing
  var out_handshake_message: seq[NoisePublicKey] = @[]

  # Here, we store the currently processed public key from the handshake message
  var curr_pk: NoisePublicKey

  #We process each message pattern token
  for token in tokens:
    case token
    of T_e:

      if reading:
        trace "noise read e"

        if in_handshake_message.len > 0:
          curr_pk = in_handshake_message[0]
        else:
          raise newException(NoiseHandshakeError, "Noise read e, expected a public key")

        # We check if current key is encrypted or not
        # Note: by specification, ephemeral keys should always be unencrypted. But we support encrypted ones
        if curr_pk.flag == 0.uint8:

          # Unencrypted Public Key 
          # Sets re and calls MixHash(re.public_key).
          hs.re = intoCurve25519Key(curr_pk.pk)
          hs.ss.mixHash(hs.re)

        # The following is out of specification: we call decryptAndHash for encrypted ephemeral keys, similarly as for static keys
        elif curr_pk.flag == 1.uint8:

          #Encrypted public key
          # Decrypts re, sets re and calls MixHash(re.public_key).
          hs.re = intoCurve25519Key(hs.ss.decryptAndHash(curr_pk.pk))

        else:
          raise newException(NoisePublicKeyError, "Noise read e, incorrect encryption flag for public key")
 
        # Noise specification: section 9.2
        # In non-PSK handshakes, the "e" token in a pre-message pattern or message pattern always results 
        # in a call to MixHash(e.public_key). 
        # In a PSK handshake, all of these calls are followed by MixKey(e.public_key).
        if "psk" in hs.handshake_pattern.name:
          hs.ss.mixKey(hs.re)

        # We delete processed public key
        in_handshake_message.delete(0)

      elif writing:
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
        out_handshake_message.add keyPairToNoisePublicKey(hs.e)

    of T_s:

      if reading:
        trace "noise read s"

        if in_handshake_message.len > 0:
          curr_pk = in_handshake_message[0]
        else:
          raise newException(NoiseHandshakeError, "Noise read s, expected a public key")

        # We check if current key is encrypted or not
        if curr_pk.flag == 0.uint8:

          # Unencrypted Public Key 
          # Sets re and calls MixHash(re.public_key).
          hs.rs = intoCurve25519Key(curr_pk.pk)
          hs.ss.mixHash(hs.rs)

        elif curr_pk.flag == 1.uint8:

          # Encrypted public key
          # Decrypts rs, sets rs and calls MixHash(rs.public_key).
          hs.rs = intoCurve25519Key(hs.ss.decryptAndHash(curr_pk.pk))

        else:
          raise newException(NoisePublicKeyError, "Noise read s, incorrect encryption flag for public key")
 
        # We delete processed public key
        in_handshake_message.delete(0)


      elif writing:
        trace "noise write s"

        if hs.s == default(KeyPair):
          raise newException(NoiseMalformedHandshake, "Static key not set")

        #We update the state
        let enc_s = hs.ss.encryptAndHash(hs.s.publicKey)

        #We add the static public key to the Waku payload
        #Note that enc_s = (Enc(s) || tag) if encryption key is set otherwise enc_s = s.
        #We distinguish these two cases by checking length of encryption
        if enc_s.len > Curve25519Key.len:
          out_handshake_message.add NoisePublicKey(flag: 1, pk: enc_s)
        else:
          out_handshake_message.add NoisePublicKey(flag: 0, pk: enc_s)

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

      # We check keys are correctly set and we then
      # call MixKey(DH(e, rs)) if initiator, MixKey(DH(s, re)) if responder.
      if hs.initiator:
        if hs.e == default(KeyPair) or hs.rs == default(Curve25519Key):
          raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))
      else:
        if hs.re == default(Curve25519Key) or hs.s == default(KeyPair):
          raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))

    of T_se:

      trace "noise dh se"

      # We check keys are correctly set and we then
      # call MixKey(DH(s, re)) if initiator, MixKey(DH(e, rs)) if responder.
      if hs.initiator:
        if hs.s == default(KeyPair) or hs.re == default(Curve25519Key):
          raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")
        hs.ss.mixKey(dh(hs.s.privateKey, hs.re))
      else:
        if hs.rs == default(Curve25519Key) or hs.e == default(KeyPair):
          raise newException(NoiseMalformedHandshake, "Local or remote ephemeral/static key not set")
        hs.ss.mixKey(dh(hs.e.privateKey, hs.rs))

    of T_ss:

      trace "noise dh ss"

      if hs.s == default(KeyPair) or hs.rs == default(Curve25519Key):
        raise newException(NoiseMalformedHandshake, "Local or remote static key not set")

      # Calls MixKey(DH(s, rs)).
      hs.ss.mixKey(dh(hs.s.privateKey, hs.rs))

  return ok(out_handshake_message)


## Procedures to progress handshakes between users

# Initialization of handshake state
proc initialize*(hs_pattern: HandshakePattern, staticKey: KeyPair = default(KeyPair), prologue: seq[byte] = @[], psk: seq[byte] = @[], pre_message_pks: seq[NoisePublicKey] = @[], initiator: bool = false): HandshakeState 
  {.raises: [Defect, NoiseMalformedHandshake, NoiseHandshakeError, NoisePublicKeyError].} =
  var hs = HandshakeState.init(hs_pattern)
  hs.ss.mixHash(prologue)
  hs.s = staticKey
  hs.psk = psk
  hs.msg_pattern_idx = 0
  hs.initiator = initiator
  processPreMessagePatternTokens(hs, pre_message_pks)
  return hs

# Advance 1 step in handshake
proc stepHandshake*(rng: var BrHmacDrbgContext, hs: var HandshakeState, readPayloadV2: PayloadV2 = default(PayloadV2), transport_message: seq[byte] = @[]): Result[HandshakeStepResult, cstring]
  {.raises: [Defect, NoiseHandshakeError, NoiseMalformedHandshake, NoisePublicKeyError, NoiseDecryptTagError, NoiseNonceMaxError].} =

  var res: HandshakeStepResult

  # If there are no more message patterns left for processing 
  # we return an empty HandshakeStepResult
  if hs.msg_pattern_idx > uint8(hs.handshake_pattern.message_patterns.len - 1):
    debug "stepHandshake called more times than the number of message patterns present in handshake"
    return ok(res)

  ### MESSAGE PATTERN

  # We get if the user is reading or writing the input handshake message
  let direction = hs.handshake_pattern.message_patterns[hs.msg_pattern_idx].direction
  var (reading, writing) = getReadingWritingState(hs, direction)
 
  if writing:
    # We write an answer to the handshake step
    # We initialize a payload v2 and we set protocol ID (if supported)
    try:
      res.payload2.protocol_id = PayloadV2ProtocolIDs[hs.handshake_pattern.name]
    except:
      raise newException(NoiseMalformedHandshake, "Handshake Pattern not supported")

    # We set the handshake and transport message
    res.payload2.handshake_message = processMessagePatternTokens(rng, hs).get()
    res.payload2.transport_message = processMessagePatternPayload(hs, transport_message)

  elif reading:
    
    # We read an answer to the handshake step
    # We process the read public keys and (eventually decrypt) the read transport message
    let 
      read_handshake_message = readPayloadV2.handshake_message
      read_transport_message = readPayloadV2.transport_message

    # Since we only read, nothing meanigful (i.e. public keys) are returned
    discard processMessagePatternTokens(rng, hs, read_handshake_message)
    # We retrieve the (decrypted) received transport message
    res.transport_message = processMessagePatternPayload(hs, read_transport_message)

  else:
    raise newException(NoiseHandshakeError, "Handshake Error: neither writing or reading user")

  #We increase the handshake state message pattern index
  hs.msg_pattern_idx += 1

  return ok(res)


proc finalizeHandshake*(hs: var HandshakeState): HandshakeResult =

  ## Noise specification, Section 5:
  ## Processing the final handshake message returns two CipherState objects, 
  ## the first for encrypting transport messages from initiator to responder, 
  ## and the second for messages in the other direction.

  let (cs1, cs2) = hs.ss.split()

  if hs.initiator:
    result.cs_write = cs1
    result.cs_read = cs2
  else:
    result.cs_write = cs2
    result.cs_read = cs1

  result.rs = hs.rs
  result.h = hs.ss.h


# After-handshake procedures 

## Noise specification, Section 5:
## Transport messages are then encrypted and decrypted by calling EncryptWithAd() 
## and DecryptWithAd() on the relevant CipherState with zero-length associated data. 
## If DecryptWithAd() signals an error due to DECRYPT() failure, then the input message is discarded. 
## The application may choose to delete the CipherState and terminate the session on such an error, 
## or may continue to attempt communications. If EncryptWithAd() or DecryptWithAd() signal an error 
## due to nonce exhaustion, then the application must delete the CipherState and terminate the session.

proc writeMessage*(hsr: var HandshakeResult, transport_message: seq[byte]): PayloadV2
  {.raises: [Defect, NoiseNonceMaxError].} =

  # According to 35/WAKU2-NOISE RFC, no Handshake protocol information is sent when exchanging messages
  result.protocol_id = 0.uint8
  result.transport_message = encryptWithAd(hsr.cs_write, @[], transport_message)


proc readMessage*(hsr: var HandshakeResult, readPayload2: PayloadV2): Result[seq[byte], cstring]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =

  var res: seq[byte]

  # According to 35/WAKU2-NOISE RFC, no Handshake protocol information is sent when exchanging messages
  if readPayload2.protocol_id == 0.uint8:
    
    # On application level we decide to discard messages which fail decryption 
    # (this because an attacker may flood the content topic were messages are being exchanged)
    try:
      res = decryptWithAd(hsr.cs_read, @[], readPayload2.transport_message)
    except NoiseDecryptTagError:
      res = @[]

  return ok(res)
