# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [Defect].}

import std/[oids, strformat, options, math, tables]
import chronos
import chronicles
import bearssl
import strutils
import stew/[results, endians2, byteutils]
import nimcrypto/[utils, sha2, hmac]

import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519, hkdf]
import libp2p/protocols/secure/secure


logScope:
  topics = "wakunoise"

#################################################################

# Constants and data structures

const
  # EmptyKey represents a non-initialized ChaChaPolyKey
  EmptyKey = default(ChaChaPolyKey)
  # The maximum ChaChaPoly allowed nonce in Noise Handshakes
  NonceMax = uint64.high - 1

type
  # Default underlying elliptic curve arithmetic (useful for switching to multiple ECs)
  # Current default is Curve25519
  EllipticCurveKey = Curve25519Key

  # An EllipticCurveKey (public, private) key pair
  KeyPair* = object
    privateKey: EllipticCurveKey
    publicKey: EllipticCurveKey

  # A Noise public key is a public key exchanged during Noise handshakes (no private part)
  # This follows https://rfc.vac.dev/spec/35/#public-keys-serialization
  # pk contains the X coordinate of the public key, if unencrypted (this implies flag = 0)
  # or the encryption of the X coordinate concatenated with the authorization tag, if encrypted (this implies flag = 1)
  # Note: besides encryption, flag can be used to distinguish among multiple supported Elliptic Curves
  NoisePublicKey* = object
    flag: uint8
    pk: seq[byte]

  # A ChaChaPoly ciphertext (data) + authorization tag (tag)
  ChaChaPolyCiphertext* = object
    data*: seq[byte]
    tag*: ChaChaPolyTag

  # A ChaChaPoly Cipher State containing key (k), nonce (nonce) and associated data (ad)
  ChaChaPolyCipherState* = object
    k: ChaChaPolyKey
    nonce: ChaChaPolyNonce
    ad: seq[byte]

  # PayloadV2 defines an object for Waku payloads with version 2 as in
  # https://rfc.vac.dev/spec/35/#public-keys-serialization
  # It contains a protocol ID field, the handshake message (for Noise handshakes) and 
  # a transport message (for Noise handshakes and ChaChaPoly encryptions)
  PayloadV2* = object
    protocolId: uint8
    handshakeMessage: seq[NoisePublicKey]
    transportMessage: seq[byte]


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

  # Some useful error types
  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseEmptyChaChaPolyInput* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError

# Supported Noise Handshake Patterns
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

#################################################################

# Utilities

# Generates random byte sequences of given size
proc randomSeqByte*(rng: var BrHmacDrbgContext, size: int): seq[byte] =
  var output = newSeq[byte](size.uint32)
  brHmacDrbgGenerate(rng, output)
  return output

# Generate random (public, private) Elliptic Curve key pairs
proc genKeyPair*(rng: var BrHmacDrbgContext): KeyPair =
  var keyPair: KeyPair
  keyPair.privateKey = EllipticCurveKey.random(rng)
  keyPair.publicKey = keyPair.privateKey.public()
  return keyPair

#Printing Handshake Patterns
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

#################################################################

# ChaChaPoly Symmetric Cipher

# ChaChaPoly encryption
# It takes a Cipher State (with key, nonce, and associated data) and encrypts a plaintext
# The cipher state in not changed
proc encrypt*(
    state: ChaChaPolyCipherState,
    plaintext: openArray[byte]): ChaChaPolyCiphertext
    {.noinit, raises: [Defect, NoiseEmptyChaChaPolyInput].} =
  # If plaintext is empty, we raise an error
  if plaintext == @[]:
    raise newException(NoiseEmptyChaChaPolyInput, "Tried to encrypt empty plaintext")
  var ciphertext: ChaChaPolyCiphertext
  # Since ChaChaPoly's library "encrypt" primitive directly changes the input plaintext to the ciphertext,
  # we copy the plaintext into the ciphertext variable and we pass the latter to encrypt
  ciphertext.data.add plaintext
  #TODO: add padding
  # ChaChaPoly.encrypt takes as input: the key (k), the nonce (nonce), a data structure for storing the computed authorization tag (tag), 
  # the plaintext (overwritten to ciphertext) (data), the associated data (ad)
  ChaChaPoly.encrypt(state.k, state.nonce, ciphertext.tag, ciphertext.data, state.ad)
  return ciphertext

# ChaChaPoly decryption
# It takes a Cipher State (with key, nonce, and associated data) and decrypts a ciphertext
# The cipher state is not changed
proc decrypt*(
    state: ChaChaPolyCipherState, 
    ciphertext: ChaChaPolyCiphertext): seq[byte]
    {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseDecryptTagError].} =
  # If ciphertext is empty, we raise an error
  if ciphertext.data == @[]:
    raise newException(NoiseEmptyChaChaPolyInput, "Tried to decrypt empty ciphertext")
  var
    # The input authorization tag
    tagIn = ciphertext.tag
    # The authorization tag computed during decryption
    tagOut: ChaChaPolyTag
  # Since ChaChaPoly's library "decrypt" primitive directly changes the input ciphertext to the plaintext,
  # we copy the ciphertext into the plaintext variable and we pass the latter to decrypt
  var plaintext = ciphertext.data
  # ChaChaPoly.decrypt takes as input: the key (k), the nonce (nonce), a data structure for storing the computed authorization tag (tag), 
  # the ciphertext (overwritten to plaintext) (data), the associated data (ad)
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, plaintext, state.ad)
  #TODO: add unpadding
  trace "decrypt", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.nonce
  # We check if the authorization tag computed while decrypting is the same as the input tag
  if tagIn != tagOut:
    debug "decrypt failed", plaintext = shortLog(plaintext)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")
  return plaintext

# Generates a random ChaChaPoly Cipher State for testing encryption/decryption
proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  var randomCipherState: ChaChaPolyCipherState
  brHmacDrbgGenerate(rng, randomCipherState.k)
  brHmacDrbgGenerate(rng, randomCipherState.nonce)
  randomCipherState.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, randomCipherState.ad)
  return randomCipherState


#################################################################

# Noise Public keys 

# Checks equality between two Noise public keys
proc `==`(k1, k2: NoisePublicKey): bool =
  return (k1.flag == k2.flag) and (k1.pk == k2.pk)
  
# Converts a (public, private) Elliptic Curve keypair to an unencrypted Noise public key (only public part)
proc keyPairToNoisePublicKey*(keyPair: KeyPair): NoisePublicKey =
  var noisePublicKey: NoisePublicKey
  noisePublicKey.flag = 0
  noisePublicKey.pk = getBytes(keyPair.publicKey)
  return noisePublicKey

# Generates a random Noise public key
proc genNoisePublicKey*(rng: var BrHmacDrbgContext): NoisePublicKey =
  var noisePublicKey: NoisePublicKey
  # We generate a random key pair
  let keyPair: KeyPair = genKeyPair(rng)
  # Since it is unencrypted, flag is 0
  noisePublicKey.flag = 0
  # We copy the public X coordinate of the key pair to the output Noise public key
  noisePublicKey.pk = getBytes(keyPair.publicKey)
  return noisePublicKey

# Converts a Noise public key to a stream of bytes as in 
# https://rfc.vac.dev/spec/35/#public-keys-serialization
proc serializeNoisePublicKey*(noisePublicKey: NoisePublicKey): seq[byte] =
  var serializedNoisePublicKey: seq[byte]
  # Public key is serialized as (flag || pk)
  # Note that pk contains the X coordinate of the public key if unencrypted
  # or the encryption concatenated with the authorization tag if encrypted 
  serializedNoisePublicKey.add noisePublicKey.flag
  serializedNoisePublicKey.add noisePublicKey.pk
  return serializedNoisePublicKey

# Converts a serialized Noise public key to a NoisePublicKey object as in
# https://rfc.vac.dev/spec/35/#public-keys-serialization
proc intoNoisePublicKey*(serializedNoisePublicKey: seq[byte]): NoisePublicKey
  {.raises: [Defect, NoisePublicKeyError].} =
  var noisePublicKey: NoisePublicKey
  # We retrieve the encryption flag
  noisePublicKey.flag = serializedNoisePublicKey[0]
  # If not 0 or 1 we raise a new exception
  if not (noisePublicKey.flag == 0 or noisePublicKey.flag == 1):
    raise newException(NoisePublicKeyError, "Invalid flag in serialized public key")
  # We set the remaining sequence to the pk value (this may be an encrypted or not encrypted X coordinate)
  noisePublicKey.pk = serializedNoisePublicKey[1..<serializedNoisePublicKey.len]
  return noisePublicKey

# Encrypts a Noise public key using a ChaChaPoly Cipher State
proc encryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseNonceMaxError].} =
  var encryptedNoisePublicKey: NoisePublicKey
  # We proceed with encryption only if 
  # - a key is set in the cipher state 
  # - the public key is unencrypted
  if cs.k != EmptyKey and noisePublicKey.flag == 0:
    let encPk = encrypt(cs, noisePublicKey.pk)
    # We set the flag to 1, since encrypted
    encryptedNoisePublicKey.flag = 1
    # Authorization tag is appendend to the ciphertext
    encryptedNoisePublicKey.pk = encPk.data
    encryptedNoisePublicKey.pk.add encPk.tag
  # Otherwise we return the public key as it is
  else:
    encryptedNoisePublicKey = noisePublicKey
  return encryptedNoisePublicKey

# Decrypts a Noise public key using a ChaChaPoly Cipher State
proc decryptNoisePublicKey*(cs: ChaChaPolyCipherState, noisePublicKey: NoisePublicKey): NoisePublicKey
  {.raises: [Defect, NoiseEmptyChaChaPolyInput, NoiseDecryptTagError].} =
  var decryptedNoisePublicKey: NoisePublicKey
  # We proceed with decryption only if 
  # - a key is set in the cipher state 
  # - the public key is encrypted
  if cs.k != EmptyKey and noisePublicKey.flag == 1:
    # Since the pk field would contain an encryption + tag, we retrieve the ciphertext length
    let pkLen = noisePublicKey.pk.len - ChaChaPolyTag.len
    # We isolate the ciphertext and the authorization tag
    let pk = noisePublicKey.pk[0..<pkLen]
    let pkAuth = intoChaChaPolyTag(noisePublicKey.pk[pkLen..<pkLen+ChaChaPolyTag.len])
    # We convert it to a ChaChaPolyCiphertext
    let ciphertext = ChaChaPolyCiphertext(data: pk, tag: pkAuth) 
    # We run decryption and store its value to a non-encrypted Noise public key (flag = 0)
    decryptedNoisePublicKey.pk = decrypt(cs, ciphertext)
    decryptedNoisePublicKey.flag = 0
  # Otherwise we return the public key as it is
  else:
    decryptedNoisePublicKey = noisePublicKey
  return decryptedNoisePublicKey

#################################################################

# Payload encoding/decoding procedures

# Checks equality between two PayloadsV2 objects
proc `==`(p1, p2: PayloadV2): bool =
  return (p1.protocolId == p2.protocolId) and 
         (p1.handshakeMessage == p2.handshakeMessage) and 
         (p1.transportMessage == p2.transportMessage) 
  

# Generates a random PayloadV2
proc randomPayloadV2*(rng: var BrHmacDrbgContext): PayloadV2 =
  var payload2: PayloadV2
  # To generate a random protocol id, we generate a random 1-byte long sequence, and we convert the first element to uint8
  payload2.protocolId = randomSeqByte(rng, 1)[0].uint8
  # We set the handshake message to three unencrypted random Noise Public Keys
  payload2.handshakeMessage = @[genNoisePublicKey(rng), genNoisePublicKey(rng), genNoisePublicKey(rng)]
  # We set the transport message to a random 128-bytes long sequence
  payload2.transportMessage = randomSeqByte(rng, 128)
  return payload2


# Serializes a PayloadV2 object to a byte sequences according to https://rfc.vac.dev/spec/35/.
# The output serialized payload concatenates the input PayloadV2 object fields as
# payload = ( protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
# The output can be then passed to the payload field of a WakuMessage https://rfc.vac.dev/spec/14/
proc serializePayloadV2*(self: PayloadV2): Result[seq[byte], cstring] =

  #We collect public keys contained in the handshake message
  var
    # According to https://rfc.vac.dev/spec/35/, the maximum size for the handshake message is 256 bytes, that is 
    # the handshake message length can be represented with 1 byte only. (its length can be stored in 1 byte)
    # However, to ease public keys length addition operation, we declare it as int and later cast to uit8
    serializedHandshakeMessageLen: int = 0
    # This variables will store the concatenation of the serializations of all public keys in the handshake message
    serializedHandshakeMessage = newSeqOfCap[byte](256)
    # A variable to store the currently processed public key serialization
    serializedPk: seq[byte]
  # For each public key in the handshake message
  for pk in self.handshakeMessage:
    # We serialize the public key
    serializedPk = serializeNoisePublicKey(pk)
    # We sum its serialized length to the total
    serializedHandshakeMessageLen +=  serializedPk.len
    # We add its serialization to the concatenation of all serialized public keys in the handshake message 
    serializedHandshakeMessage.add serializedPk
    # If we are processing more than 256 byte, we return an error
    if serializedHandshakeMessageLen > uint8.high.int:
      debug "PayloadV2 malformed: too many public keys contained in the handshake message"
      return err("Too many public keys in handshake message")


  # We get the transport message byte length
  let transportMessageLen = self.transportMessage.len

  # The output payload as in https://rfc.vac.dev/spec/35/. We concatenate all the PayloadV2 fields as 
  # payload = ( protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
  # We declare it as a byte sequence of length accordingly to the PayloadV2 information read 
  var payload = newSeqOfCap[byte](1 + # 1 byte for protocol ID             
                                  1 + # 1 byte for length of serializedHandshakeMessage field
                                  serializedHandshakeMessageLen + # serializedHandshakeMessageLen bytes for serializedHandshakeMessage
                                  8 + # 8 bytes for transportMessageLen
                                  transportMessageLen # transportMessageLen bytes for transportMessage
                                  )
  
  # We concatenate all the data
  # The protocol ID (1 byte) and handshake message length (1 byte) can be directly casted to byte to allow direct copy to the payload byte sequence
  payload.add self.protocolId.byte
  payload.add serializedHandshakeMessageLen.byte
  payload.add serializedHandshakeMessage
  # The transport message length is converted from uint64 to bytes in Little-Endian
  payload.add toBytesLE(transportMessageLen.uint64)
  payload.add self.transportMessage

  return ok(payload)



# Deserializes a byte sequence to a PayloadV2 object according to https://rfc.vac.dev/spec/35/.
# The input serialized payload concatenates the output PayloadV2 object fields as
# payload = ( protocolId || serializedHandshakeMessageLen || serializedHandshakeMessage || transportMessageLen || transportMessage)
proc deserializePayloadV2*(payload: seq[byte]): Result[PayloadV2, cstring]
  {.raises: [Defect, NoisePublicKeyError].} =

  # The output PayloadV2
  var payload2: PayloadV2

  # i is the read input buffer position index
  var i: uint64 = 0

  # We start reading the Protocol ID
  # TODO: when the list of supported protocol ID is defined, check if read protocol ID is supported
  payload2.protocolId = payload[i].uint8
  i += 1

  # We read the Handshake Message lenght (1 byte)
  var handshakeMessageLen = payload[i].uint64
  if handshakeMessageLen > uint8.high.uint64:
    debug "Payload malformed: too many public keys contained in the handshake message"
    #raise newException(NoiseMalformedHandshake, "Too many public keys in handshake message")
    return err("Too many public keys in handshake message")

  i += 1

  # We now read for handshakeMessageLen bytes the buffer and we deserialize each (encrypted/unencrypted) public key read
  var
    # In handshakeMessage we accumulate the read deserialized Noise Public keys
    handshakeMessage: seq[NoisePublicKey]
    flag: byte
    pkLen: uint64
    written: uint64 = 0

  # We read the buffer until handshakeMessageLen are read
  while written != handshakeMessageLen:
    # We obtain the current Noise Public key encryption flag
    flag = payload[i]
    # If the key is unencrypted, we only read the X coordinate of the EC public key and we deserialize into a Noise Public Key
    if flag == 0:
      pkLen = 1 + EllipticCurveKey.len
      handshake_message.add intoNoisePublicKey(payload[i..<i+pkLen])
      i += pkLen
      written += pkLen
    # If the key is encrypted, we only read the encrypted X coordinate and the authorization tag, and we deserialize into a Noise Public Key
    elif flag == 1:
      pkLen = 1 + EllipticCurveKey.len + ChaChaPolyTag.len
      handshakeMessage.add intoNoisePublicKey(payload[i..<i+pkLen])
      i += pkLen
      written += pkLen
    else:
      return err("Invalid flag for Noise public key")


  # We save in the output PayloadV2 the read handshake message
  payload2.handshakeMessage = handshakeMessage

  # We read the transport message length (8 bytes) and we convert to uint64 in Little Endian
  let transportMessageLen = fromBytesLE(uint64, payload[i..(i+8-1)])
  i += 8

  # We read the transport message (handshakeMessage bytes) 
  payload2.transportMessage = payload[i..i+transportMessageLen-1]
  i += transportMessageLen

  return ok(payload2)
