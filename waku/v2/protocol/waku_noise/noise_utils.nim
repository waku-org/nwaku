# Waku Noise Protocols for Waku Payload Encryption
# Noise utilities module
## See spec for more details:
## https://github.com/vacp2p/rfc/tree/master/content/docs/rfcs/35

{.push raises: [Defect].}

import std/[oids, options, strutils, tables, sequtils]
import chronos
import chronicles
import bearssl/rand
import stew/[results, endians2, byteutils]
import nimcrypto/[utils, sha2, hmac]

import libp2p/errors
import libp2p/crypto/[chacha20poly1305, curve25519]

import ./noise_types
import ./noise

logScope:
  topics = "wakunoise"

#################################################################

#################################
# Generic Utilities
#################################

# Generates random byte sequences of given size
proc randomSeqByte*(rng: var HmacDrbgContext, size: int): seq[byte] =
  var output = newSeq[byte](size.uint32)
  hmacDrbgGenerate(rng, output)
  return output

# Pads a payload according to PKCS#7 as per RFC 5652 https://datatracker.ietf.org/doc/html/rfc5652#section-6.3
proc pkcs7_pad*(payload: seq[byte], paddingSize: int): seq[byte] =
  
  assert(paddingSize<256)

  let k = paddingSize - (payload.len mod paddingSize)
  
  var padding: seq[byte]

  if k != 0:
    padding = newSeqWith(k, k.byte)
  else:
    padding = newSeqWith(paddingSize, paddingSize.byte)

  let padded = concat(payload, padding)

  return padded

# Unpads a payload according to PKCS#7 as per RFC 5652 https://datatracker.ietf.org/doc/html/rfc5652#section-6.3
proc pkcs7_unpad*(payload: seq[byte], paddingSize: int): seq[byte] =
  let k = payload[payload.high]
  let unpadded = payload[0..payload.high-k.int]
  return unpadded

# Simple utility that checks if the given variable is "default", 
# Therefore, it has not been initialized
proc isDefault*[T](value: T): bool = 
  value == static(default(T))

#################################################################

#################################
# Noise Handhshake Utilities
#################################

# Generate random (public, private) Elliptic Curve key pairs
proc genKeyPair*(rng: var HmacDrbgContext): KeyPair =
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
    # We iterate over pre message patterns, if any
    if self.preMessagePatterns != EmptyPreMessage:
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
    # We iterate over message patterns
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
proc hashProtocol*(protocolName: string): MDigest[256] =

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

#################################
# ChaChaPoly Cipher utilities
#################################

# Generates a random ChaChaPolyKey for testing encryption/decryption
proc randomChaChaPolyKey*(rng: var HmacDrbgContext): ChaChaPolyKey =
  var key: ChaChaPolyKey
  hmacDrbgGenerate(rng, key)
  return key

# Generates a random ChaChaPoly Cipher State for testing encryption/decryption
proc randomChaChaPolyCipherState*(rng: var HmacDrbgContext): ChaChaPolyCipherState =
  var randomCipherState: ChaChaPolyCipherState
  randomCipherState.k = randomChaChaPolyKey(rng)
  hmacDrbgGenerate(rng, randomCipherState.nonce)
  randomCipherState.ad = newSeq[byte](32)
  hmacDrbgGenerate(rng, randomCipherState.ad)
  return randomCipherState

#################################################################

#################################
# Noise Public keys utilities
#################################

# Checks equality between two Noise public keys
proc `==`*(k1, k2: NoisePublicKey): bool =
  return (k1.flag == k2.flag) and (k1.pk == k2.pk)
  
# Converts a public Elliptic Curve key to an unencrypted Noise public key
proc toNoisePublicKey*(publicKey: EllipticCurveKey): NoisePublicKey =
  var noisePublicKey: NoisePublicKey
  noisePublicKey.flag = 0
  noisePublicKey.pk = getBytes(publicKey)
  return noisePublicKey

# Generates a random Noise public key
proc genNoisePublicKey*(rng: var HmacDrbgContext): NoisePublicKey =
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
proc `==`*(p1, p2: PayloadV2): bool =
  return (p1.protocolId == p2.protocolId) and 
         (p1.handshakeMessage == p2.handshakeMessage) and 
         (p1.transportMessage == p2.transportMessage) 
  

# Generates a random PayloadV2
proc randomPayloadV2*(rng: var HmacDrbgContext): PayloadV2 =
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

  # We collect public keys contained in the handshake message
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
