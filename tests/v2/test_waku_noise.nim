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

  test "Encode/decode PayloadV2 to byte sequence":

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

  test "Noise XX Handhshake and message encryption (extended test)":

    let handshake_pattern = NoiseHandshakePatterns["XX"]

    let aliceStaticKey = genKeyPair(rng[])
    var aliceHS = initialize(handshake_pattern, staticKey = aliceStaticKey, initiator = true)

    let bobStaticKey = genKeyPair(rng[])
    var bobHS = initialize(handshake_pattern, staticKey = bobStaticKey)
    
    var 
      test_transport_message: seq[byte]
      aliceStep, bobStep: HandshakeStepResult 
    
    # Here the handshake starts
    # Write and read calls alternate between Alice and Bob

    ###############
    # 1st step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # By being initiator, Alice writes a Waku2 payload v2 containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    ###############
    # 2nd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Now Bob writes and returns a payload
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()

    # While Alice reads and returns the (decrypted) transport message
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    
    check aliceStep.transport_message == test_transport_message

    ###############
    # 3rd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32) 
    # Similarly as in first step, Alice writes a Waku2 payload containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    # Note that no more message patterns are left for processing 
    # Another call to stepHandshake would have returned an empty HandshakeStepResult
    # We test that extra calls do not affect handshake finalization
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
   
    #########################
    # After Handshake
    #########################
    # We finalize the handshake to retrieve the Inbound/Outbound symmetric states
    var aliceHSResult, bobHSResult: HandshakeResult

    aliceHSResult = finalizeHandshake(aliceHS)
    bobHSResult = finalizeHandshake(bobHS)

    # We test read/write of random messages between Alice and Bob
    var 
      payload2: PayloadV2
      sent_message: seq[byte]
      read_message: seq[byte]

    for _ in 0..10:
      # Alice writes to Bob
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(aliceHSResult, sent_message)
      read_message = readMessage(bobHSResult, payload2).get()
      check sent_message == read_message
      # Bob writes to Alice
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(bobHSResult, sent_message)
      read_message = readMessage(aliceHSResult, payload2).get()
      check sent_message == read_message

  test "Noise XXpsk0 Handhshake and message encryption (short test)":

    let handshake_pattern = NoiseHandshakePatterns["XXpsk0"]

    let psk = randomSeqByte(rng[], 32)

    let aliceStaticKey = genKeyPair(rng[])
    var aliceHS = initialize(handshake_pattern, staticKey = aliceStaticKey, psk = psk, initiator = true)

    let bobStaticKey = genKeyPair(rng[])
    var bobHS = initialize(handshake_pattern, staticKey = bobStaticKey, psk = psk)
    
    var 
      test_transport_message: seq[byte]
      aliceStep, bobStep: HandshakeStepResult 
    
    # Here the handshake starts
    # Write and read calls alternate between Alice and Bob

    ###############
    # 1st step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # By being initiator, Alice writes a Waku2 payload v2 containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    ###############
    # 2nd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Now Bob writes and returns a payload
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()

    # While Alice reads and returns the (decrypted) transport message
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    
    check aliceStep.transport_message == test_transport_message

    ###############
    # 3rd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Similarly as in first step, Alice writes a Waku2 payload containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    # Note that no more message patterns are left for processing 
    # Another call to stepHandshake would have returned an empty HandshakeStepResult
    # We test that extra calls do not affect handshake finalization
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
   
    #########################
    # After Handshake
    #########################
    # We finalize the handshake to retrieve the Inbound/Outbound symmetric states
    var aliceHSResult, bobHSResult: HandshakeResult

    aliceHSResult = finalizeHandshake(aliceHS)
    bobHSResult = finalizeHandshake(bobHS)

    # We test read/write of random messages between Alice and Bob
    var 
      payload2: PayloadV2
      sent_message: seq[byte]
      read_message: seq[byte]

    for _ in 0..10:
      # Alice writes to Bob
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(aliceHSResult, sent_message)
      read_message = readMessage(bobHSResult, payload2).get()
      check sent_message == read_message
      # Bob writes to Alice
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(bobHSResult, sent_message)
      read_message = readMessage(aliceHSResult, payload2).get()
      check sent_message == read_message

  test "Noise K1K1 Handhshake and message encryption (short test)":

    let handshake_pattern = NoiseHandshakePatterns["K1K1"]

    let aliceStaticKey = genKeyPair(rng[])
    let bobStaticKey = genKeyPair(rng[])

    # This handshake has the following pre-message pattern:
    # -> s
    # <- s
    #   ...
    # So we define accordingly the sequence of the pre-message public keys
    let pre_message_pks: seq[NoisePublicKey] = @[intoNoisePublicKey(aliceStaticKey.publicKey), intoNoisePublicKey(bobStaticKey.publicKey)]

    var aliceHS = initialize(handshake_pattern, staticKey = aliceStaticKey, pre_message_pks = pre_message_pks, initiator = true)
    var bobHS = initialize(handshake_pattern, staticKey = bobStaticKey, pre_message_pks = pre_message_pks)
    
    var 
      test_transport_message: seq[byte]
      aliceStep, bobStep: HandshakeStepResult 
    
    # Here the handshake starts
    # Write and read calls alternate between Alice and Bob

    ###############
    # 1st step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # By being initiator, Alice writes a Waku2 payload v2 containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    ###############
    # 2nd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Now Bob writes and returns a payload
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()

    # While Alice reads and returns the (decrypted) transport message
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    
    check aliceStep.transport_message == test_transport_message

    ###############
    # 3rd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Similarly as in first step, Alice writes a Waku2 payload containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    # Note that no more message patterns are left for processing 
    
    #########################
    # After Handshake
    #########################
    # We finalize the handshake to retrieve the Inbound/Outbound symmetric states
    var aliceHSResult, bobHSResult: HandshakeResult

    aliceHSResult = finalizeHandshake(aliceHS)
    bobHSResult = finalizeHandshake(bobHS)

    # We test read/write of random messages between Alice and Bob
    var 
      payload2: PayloadV2
      sent_message: seq[byte]
      read_message: seq[byte]

    for _ in 0..10:
      # Alice writes to Bob
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(aliceHSResult, sent_message)
      read_message = readMessage(bobHSResult, payload2).get()
      check sent_message == read_message
      # Bob writes to Alice
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(bobHSResult, sent_message)
      read_message = readMessage(aliceHSResult, payload2).get()
      check sent_message == read_message


  test "Noise XK1 Handhshake and message encryption (short test)":

    let handshake_pattern = NoiseHandshakePatterns["XK1"]

    let aliceStaticKey = genKeyPair(rng[])
    let bobStaticKey = genKeyPair(rng[])

    # This handshake has the following pre-message pattern:
    # <- s
    #   ...
    # So we define accordingly the sequence of the pre-message public keys
    let pre_message_pks: seq[NoisePublicKey] = @[intoNoisePublicKey(bobStaticKey.publicKey)]

    var aliceHS = initialize(handshake_pattern, staticKey = aliceStaticKey, pre_message_pks = pre_message_pks, initiator = true)
    var bobHS = initialize(handshake_pattern, staticKey = bobStaticKey, pre_message_pks = pre_message_pks)
    
    var 
      test_transport_message: seq[byte]
      aliceStep, bobStep: HandshakeStepResult 
    
    # Here the handshake starts
    # Write and read calls alternate between Alice and Bob

    ###############
    # 1st step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # By being initiator, Alice writes a Waku2 payload v2 containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    ###############
    # 2nd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Now Bob writes and returns a payload
    bobStep = stepHandshake(rng[], bobHS, transport_message = test_transport_message).get()

    # While Alice reads and returns the (decrypted) transport message
    aliceStep = stepHandshake(rng[], aliceHS, readPayloadV2 = bobStep.payload2).get()
    
    check aliceStep.transport_message == test_transport_message

    ###############
    # 3rd step
    ###############
    test_transport_message = randomSeqByte(rng[], 32)
    # Similarly as in first step, Alice writes a Waku2 payload containing the handshake_message and the (encrypted) transport_message
    aliceStep = stepHandshake(rng[], aliceHS, transport_message = test_transport_message).get()

    # Bob reads Alice's payloads, and returns the (decrypted) transport_message alice sent to him
    bobStep = stepHandshake(rng[], bobHS, readPayloadV2 = aliceStep.payload2).get()
    
    check bobStep.transport_message == test_transport_message

    # Note that no more message patterns are left for processing 
    
    #########################
    # After Handshake
    #########################
    # We finalize the handshake to retrieve the Inbound/Outbound symmetric states
    var aliceHSResult, bobHSResult: HandshakeResult

    aliceHSResult = finalizeHandshake(aliceHS)
    bobHSResult = finalizeHandshake(bobHS)

    # We test read/write of random messages between Alice and Bob
    var 
      payload2: PayloadV2
      sent_message: seq[byte]
      read_message: seq[byte]

    for _ in 0..10:
      # Alice writes to Bob
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(aliceHSResult, sent_message)
      read_message = readMessage(bobHSResult, payload2).get()
      check sent_message == read_message
      # Bob writes to Alice
      sent_message = randomSeqByte(rng[], 32)
      payload2 = writeMessage(bobHSResult, sent_message)
      read_message = readMessage(aliceHSResult, payload2).get()
      check sent_message == read_message