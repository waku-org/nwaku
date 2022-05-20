# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [Defect].}

import std/[oids, options, strutils, tables]
import chronos
import chronicles
import bearssl
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
  EmptyKey* = default(ChaChaPolyKey)
  # The maximum ChaChaPoly allowed nonce in Noise Handshakes
  NonceMax* = uint64.high - 1

type

  #################################
  # Elliptic Curve arithemtic
  #################################

  # Default underlying elliptic curve arithmetic (useful for switching to multiple ECs)
  # Current default is Curve25519
  EllipticCurve = Curve25519
  EllipticCurveKey = Curve25519Key

  # An EllipticCurveKey (public, private) key pair
  KeyPair* = object
    privateKey: EllipticCurveKey
    publicKey: EllipticCurveKey

  #################################
  # Noise Public Keys
  #################################
  
  # A Noise public key is a public key exchanged during Noise handshakes (no private part)
  # This follows https://rfc.vac.dev/spec/35/#public-keys-serialization
  # pk contains the X coordinate of the public key, if unencrypted (this implies flag = 0)
  # or the encryption of the X coordinate concatenated with the authorization tag, if encrypted (this implies flag = 1)
  # Note: besides encryption, flag can be used to distinguish among multiple supported Elliptic Curves
  NoisePublicKey* = object
    flag: uint8
    pk: seq[byte]

  #################################
  # ChaChaPoly Encryption
  #################################

  # A ChaChaPoly ciphertext (data) + authorization tag (tag)
  ChaChaPolyCiphertext* = object
    data*: seq[byte]
    tag*: ChaChaPolyTag

  # A ChaChaPoly Cipher State containing key (k), nonce (nonce) and associated data (ad)
  ChaChaPolyCipherState* = object
    k: ChaChaPolyKey
    nonce: ChaChaPolyNonce
    ad: seq[byte]

  #################################
  # Noise handshake patterns
  #################################

  # The Noise tokens appearing in Noise (pre)message patterns 
  # as in http://www.noiseprotocol.org/noise.html#handshake-pattern-basics
  NoiseTokens = enum
    T_e = "e"
    T_s = "s"
    T_es = "es"
    T_ee = "ee"
    T_se = "se"
    T_ss = "se"
    T_psk = "psk"

  # The direction of a (pre)message pattern in canonical form (i.e. Alice-initiated form)
  # as in http://www.noiseprotocol.org/noise.html#alice-and-bob
  MessageDirection* = enum
    D_r = "->"
    D_l = "<-"

  # The pre message pattern consisting of a message direction and some Noise tokens, if any.
  # (if non empty, only tokens e and s are allowed: http://www.noiseprotocol.org/noise.html#handshake-pattern-basics)
  PreMessagePattern* = object
    direction: MessageDirection
    tokens: seq[NoiseTokens]

  # The message pattern consisting of a message direction and some Noise tokens
  # All Noise tokens are allowed
  MessagePattern* = object
    direction: MessageDirection
    tokens: seq[NoiseTokens]

  # The handshake pattern object. It stores the handshake protocol name, the handshake pre message patterns and the handshake message patterns
  HandshakePattern* = object
    name*: string
    preMessagePatterns*: seq[PreMessagePattern]
    messagePatterns*: seq[MessagePattern]

  #################################
  # Noise state machine
  #################################

  # The Cipher State as in https://noiseprotocol.org/noise.html#the-cipherstate-object
  # Contains an encryption key k and a nonce n (used in Noise as a counter)
  CipherState* = object
    k: ChaChaPolyKey
    n: uint64

  # The Symmetric State as in https://noiseprotocol.org/noise.html#the-symmetricstate-object
  # Contains a Cipher State cs, the chaining key ck and the handshake hash value h
  SymmetricState* = object
    cs: CipherState
    ck: ChaChaPolyKey
    h: MDigest[256]

  # The Handshake State as in https://noiseprotocol.org/noise.html#the-handshakestate-object
  # Contains 
  #   - the local and remote ephemeral/static keys e,s,re,rs (if any)
  #   - the initiator flag (true if the user creating the state is the handshake initiator, false otherwise)
  #   - the handshakePattern (containing the handshake protocol name, and (pre)message patterns)
  # This object is futher extended from specifications by storing:
  #   - a message pattern index msgPatternIdx indicating the next handshake message pattern to process
  #   - the user's preshared psk, if any
  HandshakeState = object
    s: KeyPair
    e: KeyPair
    rs: EllipticCurveKey
    re: EllipticCurveKey
    ss: SymmetricState
    initiator: bool
    handshakePattern: HandshakePattern
    msgPatternIdx: uint8
    psk: seq[byte]

  # When a handshake is complete, the HandhshakeResult will contain the two 
  # Cipher States used to encrypt/decrypt outbound/inbound messages
  # The recipient static key rs and handshake hash values h are stored to address some possible future applications (channel-binding, session management, etc.).
  # However, are not required by Noise specifications and are thus optional
  HandshakeResult = object
    csInbound: CipherState
    csOutbound: CipherState
    # Optional fields:
    rs: EllipticCurveKey
    h: MDigest[256]

  #################################
  # Waku Payload V2
  #################################

  # PayloadV2 defines an object for Waku payloads with version 2 as in
  # https://rfc.vac.dev/spec/35/#public-keys-serialization
  # It contains a protocol ID field, the handshake message (for Noise handshakes) and 
  # a transport message (for Noise handshakes and ChaChaPoly encryptions)
  PayloadV2* = object
    protocolId: uint8
    handshakeMessage: seq[NoisePublicKey]
    transportMessage: seq[byte]

  #################################
  # Some useful error types
  #################################

  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseEmptyChaChaPolyInput* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError


#################################
# Constants (supported protocols)
#################################
const

  # The empty pre message patterns
  EmptyPreMessagePattern: seq[PreMessagePattern] = @[]

  # Supported Noise handshake patterns as defined in https://rfc.vac.dev/spec/35/#specification
  NoiseHandshakePatterns*  = {
    "K1K1":   HandshakePattern(name: "Noise_K1K1_25519_ChaChaPoly_SHA256",
                               preMessagePatterns: @[PreMessagePattern(direction: D_r, tokens: @[T_s]),
                                                     PreMessagePattern(direction: D_l, tokens: @[T_s])],
                               messagePatterns:    @[   MessagePattern(direction: D_r, tokens: @[T_e]),
                                                        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
                                                        MessagePattern(direction: D_r, tokens: @[T_se])]
                               ),

    "XK1":    HandshakePattern(name: "Noise_XK1_25519_ChaChaPoly_SHA256",
                               preMessagePatterns: @[PreMessagePattern(direction: D_l, tokens: @[T_s])], 
                               messagePatterns:    @[   MessagePattern(direction: D_r, tokens: @[T_e]),
                                                        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_es]),
                                                        MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              ),

    "XX":     HandshakePattern(name: "Noise_XX_25519_ChaChaPoly_SHA256",
                               preMessagePatterns: EmptyPreMessagePattern, 
                               messagePatterns:    @[   MessagePattern(direction: D_r, tokens: @[T_e]),
                                                        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
                                                        MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              ),

    "XXpsk0": HandshakePattern(name: "Noise_XXpsk0_25519_ChaChaPoly_SHA256",
                               preMessagePatterns: EmptyPreMessagePattern, 
                               messagePatterns:     @[  MessagePattern(direction: D_r, tokens: @[T_psk, T_e]),
                                                        MessagePattern(direction: D_l, tokens: @[T_e, T_ee, T_s, T_es]),
                                                        MessagePattern(direction: D_r, tokens: @[T_s, T_se])]
                              )
    }.toTable()


  # Supported Protocol ID for PayloadV2 objects
  # Protocol IDs are defined according to https://rfc.vac.dev/spec/35/#specification
  PayloadV2ProtocolIDs*  = {

    "":                                      0.uint8,
    "Noise_K1K1_25519_ChaChaPoly_SHA256":   10.uint8,
    "Noise_XK1_25519_ChaChaPoly_SHA256":    11.uint8,
    "Noise_XX_25519_ChaChaPoly_SHA256":     12.uint8,
    "Noise_XXpsk0_25519_ChaChaPoly_SHA256": 13.uint8,
    "ChaChaPoly":                           30.uint8

    }.toTable()


#################################################################

#################################
# Utilities
#################################

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

# Gets private key from a key pair
proc getPrivateKey*(keypair: KeyPair): EllipticCurveKey =
  return keypair.privateKey

# Gets public key from a key pair
proc getPublicKey*(keypair: KeyPair): EllipticCurveKey =
  return keypair.publicKey

# Prints Handshake Patterns using Noise pattern layout
proc print*(self: HandshakePattern) 
   {.raises: [IOError, NoiseMalformedHandshake].}=
  try:
    if self.name != "":
      stdout.write self.name, ":\n"
      stdout.flushFile()
    #We iterate over pre message patterns, if any
    if self.preMessagePatterns != EmptyPreMessagePattern:
      for pattern in self.preMessagePatterns:
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
    for pattern in self.messagePatterns:
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

# Hashes a Noise protocol name using SHA256
proc hashProtocol(protocolName: string): MDigest[256] =

  # The output hash value
  var hash: MDigest[256]

  # From Noise specification: Section 5.2 
  # http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
  # If protocol_name is less than or equal to HASHLEN bytes in length,
  # sets h equal to protocol_name with zero bytes appended to make HASHLEN bytes.
  # Otherwise sets h = HASH(protocol_name).
  if protocolName.len <= 32:
    hash.data[0..protocolName.high] = protocolName.toBytes
  else:
    hash = sha256.digest(protocolName)

  return hash

# Performs a Diffie-Hellman operation between two elliptic curve keys (one private, one public)
proc dh*(private: EllipticCurveKey, public: EllipticCurveKey): EllipticCurveKey =

  # The output result of the Diffie-Hellman operation
  var output: EllipticCurveKey

  # Since the EC multiplication writes the result to the input, we copy the input to the output variable 
  output = public
  # We execute the DH operation
  EllipticCurve.mul(output, private)

  return output


#################################################################

# Noise state machine primitives

# Overview :
# - Alice and Bob process (i.e. read and write, based on their role) each token appearing in a handshake pattern, consisting of pre-message and message patterns;
# - Both users initialize and update according to processed tokens a Handshake State, a Symmetric State and a Cipher State;
# - A preshared key psk is processed by calling MixKeyAndHash(psk);
# - When an ephemeral public key e is read or written, the handshake hash value h is updated by calling mixHash(e); If the handshake expects a psk, MixKey(e) is further called
# - When an encrypted static public key s or a payload message m is read, it is decrypted with decryptAndHash;
# - When a static public key s or a payload message is writted, it is encrypted with encryptAndHash;
# - When any Diffie-Hellman token ee, es, se, ss is read or written, the chaining key ck is updated by calling MixKey on the computed secret;
# - If all tokens are processed, users compute two new Cipher States by calling Split;
# - The two Cipher States obtained from Split are used to encrypt/decrypt outbound/inbound messages.

#################################
# Cipher State Primitives
#################################

# Checks if a Cipher State has an encryption key set
proc hasKey(cs: CipherState): bool =
  return (cs.k != EmptyKey)

# Encrypts a plaintext using key material in a Noise Cipher State
# The CipherState is updated increasing the nonce (used as a counter in Noise) by one
proc encryptWithAd*(state: var CipherState, ad, plaintext: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =

  # We raise an error if encryption is called using a Cipher State with nonce greater than  MaxNonce
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

  var ciphertext: seq[byte]

  # If an encryption key is set in the Cipher state, we proceed with encryption
  if state.hasKey:
  
    # The output is the concatenation of the ciphertext and authorization tag
    # We define its length accordingly
    ciphertext = newSeqOfCap[byte](plaintext.len + sizeof(ChaChaPolyTag))
    
    # Since ChaChaPoly encryption primitive overwrites the input with the output,
    # we copy the plaintext in the output ciphertext variable and we pass it to encryption
    ciphertext.add(plaintext)

    # The nonce is read from the input CipherState
    # By Noise specification the nonce is 8 bytes long out of the 12 bytes supported by ChaChaPoly
    var nonce: ChaChaPolyNonce
    nonce[4..<12] = toBytesLE(state.n)

    # We perform encryption and we store the authorization tag
    var authorizationTag: ChaChaPolyTag
    ChaChaPoly.encrypt(state.k, nonce, authorizationTag, ciphertext, ad)

    # We append the authorization tag to ciphertext
    ciphertext.add(authorizationTag)

    # We increase the Cipher state nonce
    inc state.n
    # If the nonce is greater than the maximum allowed nonce, we raise an exception
    if state.n > NonceMax:
      raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

    trace "encryptWithAd", authorizationTag = byteutils.toHex(authorizationTag), ciphertext = ciphertext, nonce = state.n - 1

  # Otherwise we return the input plaintext according to specification http://www.noiseprotocol.org/noise.html#the-cipherstate-object
  else:

    ciphertext = @plaintext
    debug "encryptWithAd called with no encryption key set. Returning plaintext."

  return ciphertext

# Decrypts a ciphertext using key material in a Noise Cipher State
# The CipherState is updated increasing the nonce (used as a counter in Noise) by one
proc decryptWithAd*(state: var CipherState, ad, ciphertext: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =

  # We raise an error if encryption is called using a Cipher State with nonce greater than  MaxNonce
  if state.n > NonceMax:
    raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

  var plaintext: seq[byte]

  # If an encryption key is set in the Cipher state, we proceed with decryption
  if state.hasKey:

    # We read the authorization appendend at the end of a ciphertext
    let inputAuthorizationTag = ciphertext.toOpenArray(ciphertext.len - ChaChaPolyTag.len, ciphertext.high).intoChaChaPolyTag
      
    var
      authorizationTag: ChaChaPolyTag
      nonce: ChaChaPolyNonce

    # The nonce is read from the input CipherState
    # By Noise specification the nonce is 8 bytes long out of the 12 bytes supported by ChaChaPoly
    nonce[4..<12] = toBytesLE(state.n)

    # Since ChaChaPoly decryption primitive overwrites the input with the output,
    # we copy the ciphertext (authorization tag excluded) in the output plaintext variable and we pass it to decryption  
    plaintext = ciphertext[0..(ciphertext.high - ChaChaPolyTag.len)]
    
    ChaChaPoly.decrypt(state.k, nonce, authorizationTag, plaintext, ad)

    # We check if the input authorization tag matches the decryption authorization tag
    if inputAuthorizationTag != authorizationTag:
      debug "decryptWithAd failed", plaintext = plaintext, ciphertext = ciphertext, inputAuthorizationTag = inputAuthorizationTag, authorizationTag = authorizationTag
      raise newException(NoiseDecryptTagError, "decryptWithAd failed tag authentication.")
    
    # We increase the Cipher state nonce
    inc state.n
    # If the nonce is greater than the maximum allowed nonce, we raise an exception
    if state.n > NonceMax:
      raise newException(NoiseNonceMaxError, "Noise max nonce value reached")

    trace "decryptWithAd", inputAuthorizationTag = inputAuthorizationTag, authorizationTag = authorizationTag, nonce = state.n
  
  # Otherwise we return the input ciphertext according to specification http://www.noiseprotocol.org/noise.html#the-cipherstate-object    
  else:

    plaintext = @ciphertext
    debug "decryptWithAd called with no encryption key set. Returning ciphertext."

  return plaintext

# Sets the nonce of a Cipher State
proc setNonce*(cs: var CipherState, nonce: uint64) =
  cs.n = nonce

# Sets the key of a Cipher State
proc setCipherStateKey*(cs: var CipherState, key: ChaChaPolyKey) =
  cs.k = key

# Generates a random Symmetric Cipher State for test purposes
proc randomCipherState*(rng: var BrHmacDrbgContext, nonce: uint64 = 0): CipherState =
  var randomCipherState: CipherState
  brHmacDrbgGenerate(rng, randomCipherState.k)
  setNonce(randomCipherState, nonce)
  return randomCipherState


# Gets the key of a Cipher State
proc getKey*(cs: CipherState): ChaChaPolyKey =
  return cs.k

# Gets the nonce of a Cipher State
proc getNonce*(cs: CipherState): uint64 =
  return cs.n

#################################
# Symmetric State primitives
#################################

# Initializes a Symmetric State
proc init*(_: type[SymmetricState], hsPattern: HandshakePattern): SymmetricState =
  var ss: SymmetricState
  # We compute the hash of the protocol name
  ss.h = hsPattern.name.hashProtocol
  # We initialize the chaining key ck
  ss.ck = ss.h.data.intoChaChaPolyKey
  # We initialize the Cipher state
  ss.cs = CipherState(k: EmptyKey)
  return ss

# MixKey as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Updates a Symmetric state chaining key and symmetric state
proc mixKey*(ss: var SymmetricState, inputKeyMaterial: ChaChaPolyKey) =
  # We derive two keys using HKDF
  var tempKeys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, inputKeyMaterial, [], tempKeys)
  # We update ck and the Cipher state's key k using the output of HDKF 
  ss.ck = tempKeys[0]
  ss.cs = CipherState(k: tempKeys[1])
  trace "mixKey", ck = ss.ck, k = ss.cs.k

# MixHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Hashes data into a Symmetric State's handshake hash value h
proc mixHash*(ss: var SymmetricState, data: openArray[byte]) =
  # We prepare the hash context
  var ctx: sha256
  ctx.init()
  # We add the previous handshake hash
  ctx.update(ss.h.data)
  # We append the input data
  ctx.update(data)
  # We hash and store the result in the Symmetric State's handshake hash value
  ss.h = ctx.finish()
  trace "mixHash", hash = ss.h.data

# mixKeyAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines MixKey and MixHash
proc mixKeyAndHash*(ss: var SymmetricState, inputKeyMaterial: openArray[byte]) {.used.} =
  var tempKeys: array[3, ChaChaPolyKey]
  # Derives 3 keys using HKDF, the chaining key and the input key material
  sha256.hkdf(ss.ck, inputKeyMaterial, [], tempKeys)
  # Sets the chaining key
  ss.ck = tempKeys[0]
  # Updates the handshake hash value
  ss.mixHash(tempKeys[1])
  # Updates the Cipher state's key
  # Note for later support of 512 bits hash functions: "If HASHLEN is 64, then truncates tempKeys[2] to 32 bytes."
  ss.cs = CipherState(k: tempKeys[2])

# EncryptAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines encryptWithAd and mixHash
proc encryptAndHash*(ss: var SymmetricState, plaintext: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseNonceMaxError].} =
  # The output ciphertext
  var ciphertext: seq[byte]
  # Note that if an encryption key is not set yet in the Cipher state, ciphertext will be equal to plaintex
  ciphertext = ss.cs.encryptWithAd(ss.h.data, plaintext)
  # We call mixHash over the result
  ss.mixHash(ciphertext)
  return ciphertext

# DecryptAndHash as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Combines decryptWithAd and mixHash
proc decryptAndHash*(ss: var SymmetricState, ciphertext: openArray[byte]): seq[byte]
  {.raises: [Defect, NoiseDecryptTagError, NoiseNonceMaxError].} =
  # The output plaintext
  var plaintext: seq[byte]
  # Note that if an encryption key is not set yet in the Cipher state, plaintext will be equal to ciphertext
  plaintext = ss.cs.decryptWithAd(ss.h.data, ciphertext)
  # According to specification, the ciphertext enters mixHash (and not the plaintext)
  ss.mixHash(ciphertext)
  return plaintext

# Split as per Noise specification http://www.noiseprotocol.org/noise.html#the-symmetricstate-object
# Once a handshake is complete, returns two Cipher States to encrypt/decrypt outbound/inbound messages
proc split*(ss: var SymmetricState): tuple[cs1, cs2: CipherState] =
  # Derives 2 keys using HKDF and the chaining key
  var tempKeys: array[2, ChaChaPolyKey]
  sha256.hkdf(ss.ck, [], [], tempKeys)
  # Returns a tuple of two Cipher States initialized with the derived keys
  return (CipherState(k: tempKeys[0]), CipherState(k: tempKeys[1]))

# Gets the chaining key field of a Symmetric State
proc getChainingKey*(ss: SymmetricState): ChaChaPolyKey =
  return ss.ck

# Gets the handshake hash field of a Symmetric State
proc getHandshakeHash*(ss: SymmetricState): MDigest[256] =
  return ss.h

# Gets the Cipher State field of a Symmetric State
proc getCipherState*(ss: SymmetricState): CipherState =
  return ss.cs

#################################
# Handshake State primitives
#################################

# Initializes a Handshake State
proc init*(_: type[HandshakeState], hsPattern: HandshakePattern, psk: seq[byte] = @[]): HandshakeState =
  # The output Handshake State
  var hs: HandshakeState
  # By default the Handshake State initiator flag is set to false
  # Will be set to true when the user associated to the handshake state starts an handshake
  hs.initiator = false
  # We copy the information on the handshake pattern for which the state is initialized (protocol name, handshake pattern, psk)
  hs.handshakePattern = hsPattern
  hs.psk = psk
  # We initialize the Symmetric State
  hs.ss = SymmetricState.init(hsPattern)
  return hs

#################################################################

#################################
# ChaChaPoly Symmetric Cipher
#################################

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
  trace "decrypt", tagIn = tagIn, tagOut = tagOut, nonce = state.nonce
  # We check if the authorization tag computed while decrypting is the same as the input tag
  if tagIn != tagOut:
    debug "decrypt failed", plaintext = shortLog(plaintext)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")
  return plaintext

# Generates a random ChaChaPolyKey for testing encryption/decryption
proc randomChaChaPolyKey*(rng: var BrHmacDrbgContext): ChaChaPolyKey =
  var key: ChaChaPolyKey
  brHmacDrbgGenerate(rng, key)
  return key

# Generates a random ChaChaPoly Cipher State for testing encryption/decryption
proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  var randomCipherState: ChaChaPolyCipherState
  randomCipherState.k = randomChaChaPolyKey(rng)
  brHmacDrbgGenerate(rng, randomCipherState.nonce)
  randomCipherState.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, randomCipherState.ad)
  return randomCipherState


#################################################################

#################################
# Noise Public keys 
#################################

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

#################################
# Payload encoding/decoding procedures
#################################

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
      handshakeMessage.add intoNoisePublicKey(payload[i..<i+pkLen])
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