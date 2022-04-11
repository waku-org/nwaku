# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

{.push raises: [Defect].}

import std/[oids, options]
import chronos
import chronicles
import bearssl
import nimcrypto/[utils, sha2, hmac]

import libp2p/stream/[connection]
import libp2p/peerid
import libp2p/peerinfo
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519]


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

  # Some useful error types
  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseEmptyChaChaPolyInput* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError


#################################################################

# Utilities

# Generates random byte sequences of given size
proc randomSeqByte*(rng: var BrHmacDrbgContext, size: int): seq[byte] =
  var output = newSeq[byte](size.uint32)
  brHmacDrbgGenerate(rng, output)
  return output

# Generate random Curve25519 (public, private) key pairs
proc genKeyPair*(rng: var BrHmacDrbgContext): KeyPair =
  var keyPair: KeyPair
  keyPair.privateKey = EllipticCurveKey.random(rng)
  keyPair.publicKey = keyPair.privateKey.public()
  return keyPair


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