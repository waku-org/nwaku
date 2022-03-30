{.used.}

import
  testutils/unittests,
  ../../waku/v2/protocol/waku_noise/noise,
  ../test_helpers,
  std/tables

procSuite "Waku Noise":
  
  let rng = rng()

  test "Encrypt -> decrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      enc_pk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      dec_pk: NoisePublicKey = decryptNoisePublicKey(cs, enc_pk)

    check: 
      noisePublicKey == dec_pk

  test "Decrypt unencrypted public key":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let 
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      dec_pk: NoisePublicKey = decryptNoisePublicKey(cs, noisePublicKey)

    check:
      noisePublicKey == dec_pk

  test "Encrypt -> encrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      enc_pk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      enc2_pk: NoisePublicKey = encryptNoisePublicKey(cs, enc_pk)
    
    check enc_pk == enc2_pk

  test "Encrypt -> decrypt -> decrypt public keys":

    let noisePublicKey: NoisePublicKey = genNoisePublicKey(rng[])

    let
      cs: ChaChaPolyCipherState = randomChaChaPolyCipherState(rng[])
      enc_pk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      dec_pk: NoisePublicKey = decryptNoisePublicKey(cs, enc_pk)
      dec2_pk: NoisePublicKey = decryptNoisePublicKey(cs, dec_pk)

    check: 
      dec_pk == dec2_pk

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
      enc_pk: NoisePublicKey = encryptNoisePublicKey(cs, noisePublicKey)
      serializedNoisePublicKey: seq[byte] = serializeNoisePublicKey(enc_pk)
      deserializedNoisePublicKey: NoisePublicKey = intoNoisePublicKey(serializedNoisePublicKey)
      dec_pk: NoisePublicKey = decryptNoisePublicKey(cs, deserializedNoisePublicKey)

    check:
      noisePublicKey == dec_pk