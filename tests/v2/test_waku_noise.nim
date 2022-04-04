{.used.}

import
  testutils/unittests,
  std/random,
  stew/byteutils,
  ../../waku/v2/protocol/waku_noise/noise,
  ../test_helpers

procSuite "Waku Noise":
  
  let rng = rng()

  test "ChaChaPoly Encryption/Decryption: random byte sequences":

    let cipherState = randomChaChaPolyCipherState(rng[])

    # We encrypt/decrypt random byte sequences
    let
      plaintext: seq[byte] = randomSeqByte(rng[], 64)
      ciphertext: ChaChaPolyCiphertext = encrypt(cipherState, plaintext)
      decryptedCiphertext: seq[byte] = decrypt(cipherState, ciphertext)

    check: 
      plaintext == decryptedCiphertext

  test "ChaChaPoly Encryption/Decryption: random strings":

    let cipherState = randomChaChaPolyCipherState(rng[])

    # We encrypt/decrypt random strings
    randomize()
    var plaintext: string
    for _ in .. rand(64):
      add(plaintext, char(rand(int('A') .. int('z'))))

    echo plaintext

    let
      ciphertext: ChaChaPolyCiphertext = encrypt(cipherState, plaintext.toBytes())
      decryptedCiphertext: seq[byte] = decrypt(cipherState, ciphertext)

    check: 
      plaintext.toBytes() == decryptedCiphertext

  test "Encrypt -> decrypt Noise public keys":

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

  test "Encrypt -> encrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      encryptedPk2: NoisePublicKey = encryptNoisePublicKey(cs, encryptedPk)
    
    check:
      encryptedPk == encryptedPk2

  test "Encrypt -> decrypt -> decrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, encryptedPk)
      decryptedPk2: NoisePublicKey = decryptNoisePublicKey(cs, decryptedPk)

    check: 
      decryptedPk == decryptedPk2

  test "Serialize -> deserialize public keys (unencrypted)":

    let 
      noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(noisePublicKey)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)

    check:
      noisePublicKey == deserializedNoisePublicKey

  test "Encrypt -> serialize -> deserialize -> decrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      encryptedPk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(encryptedPk)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)
      decryptedPk: NoisePublicKey = decryptNoisePublicKey(cs, deserializedNoisePublicKey)

    check:
      noisePublicKey == decryptedPk