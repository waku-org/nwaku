{.used.}

import
  testutils/unittests,
  ../../waku/v2/protocol/waku_message,
  ../../waku/v2/protocol/waku_noise/noise,
  ../../waku/v2/node/waku_payload,
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

  test "Encode/decode PayloadV2 to bytes sequence":

    let 
      payload2 = randomPayloadV2(rng[])
      encoded_payload = encodeV2(payload2)
      decoded_payload = decodeV2(encoded_payload.get())

    check: 
      payload2 == decoded_payload.get()


  test "Encode/Decode Waku2 payload (version 2) - ChaChaPoly Keyinfo":
    # Encoding
    let
      version = 2'u32
      payload = randomPayloadV2(rng[])
      encodedPayload = encodePayloadV2(payload)

    check encodedPayload.isOk()

    let
      msg = WakuMessage(payload: encodedPayload.get(), version: version)
      pb =  msg.encode()

    # Decoding
    let msgDecoded = WakuMessage.init(pb.buffer)
    check msgDecoded.isOk()

    let
      cipherState = randomChaChaPolyCipherState(rng[])
      keyInfo = KeyInfo(kind: ChaChaPolyEncryption, cs: cipherState)
      decoded = decodePayloadV2(msgDecoded.get(), keyInfo)

    check:
      decoded.isOk()
      decoded.get() == payload

  #TODO: add encrypt payload with ChaChaPoly


  test "Noise Handhshake - Handshake State Initialization (XX)":

    let aliceStaticKey = genKeyPair(rng[])
    var aliceHS = initialize(NoiseHandshakePatterns["test"], aliceStaticKey)

    let bobStaticKey = genKeyPair(rng[])
    var bobHS = initialize(NoiseHandshakePatterns["test"], aliceStaticKey)
    
    let r = startHandshake(rng[], aliceHS, transport_message = @[1.byte])