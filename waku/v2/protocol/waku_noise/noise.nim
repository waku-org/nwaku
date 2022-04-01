# Waku Noise Protocols for Waku Payload Encryption
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35
##
## Implementation partially inspired by noise-libp2p:
## https://github.com/status-im/nim-libp2p/blob/master/libp2p/protocols/secure/noise.nim

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
  #let transport_message_len_len = ceil(log(transport_message_len, 8)).int

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
