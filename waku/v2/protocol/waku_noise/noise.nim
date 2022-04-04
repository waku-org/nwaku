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
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305]

logScope:
  topics = "wakunoise"

const
  # EmptyKey is a special value which indicates a ChaChaPolyKey has not yet been initialized.
  EmptyKey = default(ChaChaPolyKey)

type
  ChaChaPolyCiphertext* = object
    data: seq[byte]
    tag: ChaChaPolyTag

  ChaChaPolyCipherState* = object
    k*: ChaChaPolyKey
    nonce*: ChaChaPolyNonce
    ad*: seq[byte]

  NoiseError* = object of LPError
  NoiseDecryptTagError* = object of NoiseError

#################################################################

# Utilities

# Generates random byte sequences of given size
proc randomSeqByte*(rng: var BrHmacDrbgContext, size: uint32): seq[byte] =
  var output = newSeq[byte](size)
  brHmacDrbgGenerate(rng, output)
  return output

#################################################################

# ChaChaPoly Symmetric Cipher

# ChaChaPoly encryption
# It takes a Cipher State (with key, nonce, and associated data) and encrypts a plaintext
proc encrypt*(
    state: ChaChaPolyCipherState,
    plaintext: openArray[byte]): ChaChaPolyCiphertext
    {.noinit, raises: [Defect].} =
  #TODO: add padding
  var ciphertext: ChaChaPolyCiphertext
  ciphertext.data.add plaintext
  ChaChaPoly.encrypt(state.k, state.nonce, ciphertext.tag, ciphertext.data, state.ad)
  return ciphertext

# ChaChaPoly decryption
# It takes a Cipher State (with key, nonce, and associated data) and decrypts a ciphertext
proc decrypt*(
    state: ChaChaPolyCipherState, 
    ciphertext: ChaChaPolyCiphertext): seq[byte]
    {.raises: [Defect, NoiseDecryptTagError].} =
  var
    tagIn = ciphertext.tag
    tagOut: ChaChaPolyTag
  var plaintext = ciphertext.data
  ChaChaPoly.decrypt(state.k, state.nonce, tagOut, plaintext, state.ad)
  #TODO: add unpadding
  trace "decrypt", tagIn = tagIn.shortLog, tagOut = tagOut.shortLog, nonce = state.nonce
  if tagIn != tagOut:
    debug "decrypt failed", plaintext = shortLog(plaintext)
    raise newException(NoiseDecryptTagError, "decrypt tag authentication failed.")
  return plaintext

# Generates a random Cipher Test for testing encryption/decryption
proc randomChaChaPolyCipherState*(rng: var BrHmacDrbgContext): ChaChaPolyCipherState =
  var randomCipherState: ChaChaPolyCipherState
  brHmacDrbgGenerate(rng, randomCipherState.k)
  brHmacDrbgGenerate(rng, randomCipherState.nonce)
  randomCipherState.ad = newSeq[byte](32)
  brHmacDrbgGenerate(rng, randomCipherState.ad)
  return randomCipherState
