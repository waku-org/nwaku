## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[oids, options, tables]
import chronos
import chronicles
import bearssl
import strutils
import stew/[endians2]
import nimcrypto/[utils, sha2, hmac]

import libp2p/stream/[connection]
import libp2p/peerid
import libp2p/peerinfo
import libp2p/protobuf/minprotobuf
import libp2p/utility
import libp2p/errors
import libp2p/crypto/[crypto, chacha20poly1305, curve25519]


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

  NoiseError* = object of LPError
  NoiseHandshakeError* = object of NoiseError
  NoiseDecryptTagError* = object of NoiseError
  NoiseNonceMaxError* = object of NoiseError # drop connection on purpose
  NoisePublicKeyError* = object of NoiseError
  NoiseMalformedHandshake* = object of NoiseError



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


# Utility

proc genKeyPair*(rng: var BrHmacDrbgContext): KeyPair =
  result.privateKey = Curve25519Key.random(rng)
  result.publicKey = result.privateKey.public()


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