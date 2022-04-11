{.used.}

import
  testutils/unittests,
  std/random,
  stew/byteutils,
  ../../waku/v2/protocol/waku_noise/noise,
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

  test "Encrypt and decrypt Noise public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, encryptedPk)

    check: 
      noisePublicKey == decryptedPk

  test "Decrypt unencrypted public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, noisePublicKey)

    check:
      noisePublicKey == decryptedPk

  test "Encrypt encrypted public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      encryptedPk2: NoisePublicKey = encryptNoisePublicKey(cs, encryptedPk)
    
    check:
      encryptedPk == encryptedPk2

  test "Encrypt, decrypt and decrypt public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, encryptedPk)
      decryptedPk2: NoisePublicKey = decryptNoisePublicKey(cs, decryptedPk)

    check: 
      decryptedPk == decryptedPk2

  test "Serialize and deserialize unencrypted public key":

    let 
      noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(noisePublicKey)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)

    check:
      noisePublicKey == deserializedNoisePublicKey

  test "Encrypt, serialize, deserialize and decrypt public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(encryptedPk)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, deserializedNoisePublicKey)

    check:
      noisePublicKey == decryptedPk