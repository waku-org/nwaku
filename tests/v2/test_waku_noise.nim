{.used.}

import
  testutils/unittests,
  std/random,
  stew/byteutils,
  ../../waku/v2/node/waku_payload,
  ../../waku/v2/protocol/waku_noise/noise,
  ../../waku/v2/protocol/waku_message,
  ../test_helpers

procSuite "Waku Noise":
  
  # We initialize the RNG in test_helpers
  let rng = rng()
  # We initialize the RNG in std/random
  randomize()

  test "ChaChaPoly Encryption/Decryption: random byte sequences":

    let cipherState = randomChaChaPolyCipherState(rng[])

    # We encrypt/decrypt random byte sequences
    let
      plaintext: seq[byte] = randomSeqByte(rng[], rand(1..128))
      ciphertext: ChaChaPolyCiphertext = encrypt(cipherState, plaintext)
      decryptedCiphertext: seq[byte] = decrypt(cipherState, ciphertext)

    check: 
      plaintext == decryptedCiphertext

  test "ChaChaPoly Encryption/Decryption: random strings":

    let cipherState = randomChaChaPolyCipherState(rng[])

    # We encrypt/decrypt random strings
    var plaintext: string
    for _ in 1..rand(1..128):
      add(plaintext, char(rand(int('A') .. int('z'))))

    let
      ciphertext: ChaChaPolyCiphertext = encrypt(cipherState, plaintext.toBytes())
      decryptedCiphertext: seq[byte] = decrypt(cipherState, ciphertext)

    check: 
      plaintext.toBytes() == decryptedCiphertext

  test "Noise public keys: encrypt and decrypt a public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, encryptedPk)

    check: 
      noisePublicKey == decryptedPk

  test "Noise public keys: decrypt an unencrypted public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, noisePublicKey)

    check:
      noisePublicKey == decryptedPk

  test "Noise public keys: encrypt an encrypted public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      encryptedPk2: NoisePublicKey = encryptNoisePublicKey(cs, encryptedPk)
    
    check:
      encryptedPk == encryptedPk2

  test "Noise public keys: encrypt, decrypt and decrypt a public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, encryptedPk)
      decryptedPk2: NoisePublicKey = decryptNoisePublicKey(cs, decryptedPk)

    check: 
      decryptedPk == decryptedPk2

  test "Noise public keys: serialize and deserialize an unencrypted public key":

    let 
      noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(noisePublicKey)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)

    check:
      noisePublicKey == deserializedNoisePublicKey

  test "Noise public keys: encrypt, serialize, deserialize and decrypt a public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(encryptedPk)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, deserializedNoisePublicKey)

    check:
      noisePublicKey == decryptedPk


  test "PayloadV2: serialize/deserialize PayloadV2 to byte sequence":

    let
      payload2: PayloadV2 = randomPayloadV2(rng[])
      serializedPayload = serializePayloadV2(payload2)

    check:
      serializedPayload.isOk()

    let deserializedPayload = deserializePayloadV2(serializedPayload.get())

    check:
      deserializedPayload.isOk()
      payload2 == deserializedPayload.get()


  test "PayloadV2: Encode/Decode a Waku Message (version 2) to a PayloadV2":
    
    # We encode to a WakuMessage a random PayloadV2
    let
      payload2 = randomPayloadV2(rng[])
      msg = encodePayloadV2(payload2)

    check:
      msg.isOk()

    # We create ProtoBuffer from WakuMessage
    let pb = msg.get().encode()

    # We decode the WakuMessage from the ProtoBuffer
    let msgFromPb = WakuMessage.init(pb.buffer)
    
    check:
      msgFromPb.isOk()

    let decoded = decodePayloadV2(msgFromPb.get())

    check:
      decoded.isOk()
      payload2 == decoded.get()