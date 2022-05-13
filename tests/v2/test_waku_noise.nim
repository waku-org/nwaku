{.used.}

import
  testutils/unittests,
  std/random,
  std/tables,
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

  test "Noise State Machine: Diffie-Hellman operation":

    #We generate random keypairs
    let
      aliceKey = genKeyPair(rng[])
      bobKey = genKeyPair(rng[])

    # A Diffie-Hellman operation between Alice's private key and Bob's public key must be equal to
    # a Diffie-hellman operation between Alice's public key and Bob's private key
    let
      dh1 = dh(getPrivateKey(aliceKey), getPublicKey(bobKey))
      dh2 = dh(getPrivateKey(bobKey), getPublicKey(aliceKey))

    check:
      dh1 == dh2

  test "Noise State Machine: Cipher State primitives":

    # We generate a random Cipher State, associated data ad and plaintext
    var 
      cipherState: CipherState = randomCipherState(rng[])
      nonce: uint64 = uint64(rand(0 .. int.high))
      ad: seq[byte] = randomSeqByte(rng[], rand(1..128))
      plaintext: seq[byte] = randomSeqByte(rng[], rand(1..128))

    # We set the random nonce generated in the cipher state
    setNonce(cipherState, nonce)
    
    # We perform encryption
    var ciphertext: seq[byte] = encryptWithAd(cipherState, ad, plaintext)

    # After any encryption/decryption operation, the Cipher State's nonce increases by 1
    check:
      getNonce(cipherState) == nonce + 1 

    # We set the nonce back to its original value for decryption
    setNonce(cipherState, nonce)

    # We decrypt (using the original nonce)
    var decrypted: seq[byte] = decryptWithAd(cipherState, ad, ciphertext)

    # We check if encryption and decryption are correct and that nonce correctly increased after decryption
    check:
      getNonce(cipherState) == nonce + 1 
      plaintext == decrypted

  test "Noise State Machine: Symmetric State primitives":

    # We select one supported handshake pattern and we initialize a symmetric state
    var 
      hsPattern = NoiseHandshakePatterns["XX"]
      symmetricState: SymmetricState =  SymmetricState.init(hsPattern)

    # We get all the Symmetric State field
    # cs : Cipher State
    # ck : chaining key
    # h : handshake hash
    var
      cs = getCipherState(symmetricState)
      ck = getChainingKey(symmetricState)
      h = getHandshakeHash(symmetricState)

    ########################################
    # mixHash
    ########################################

    # We generate a random byte sequence and execute a mixHash over it
    mixHash(symmetricState, randomSeqByte(rng[], rand(1..128)))

    # mixHash changes only the handshake hash value of the Symmetric state
    check:
      cs == getCipherState(symmetricState)
      ck == getChainingKey(symmetricState)
      h != getHandshakeHash(symmetricState)

    # We update test values
    h = getHandshakeHash(symmetricState)

    ########################################
    # mixKey
    ########################################

    # We generate random input key material and we execute mixKey
    var inputKeyMaterial = randomChaChaPolyKey(rng[])
    mixKey(symmetricState, inputKeyMaterial)

    # mixKey changes the Symmetric State's chaining key and encryption key of the embedded Cipher State 
    # It further sets to 0 the nonce of the embedded Cipher State
    check:
      getKey(cs) != getKey(getCipherState(symmetricState))
      getNonce(getCipherState(symmetricState)) == 0.uint64
      cs != getCipherState(symmetricState)
      ck != getChainingKey(symmetricState)
      h == getHandshakeHash(symmetricState)

    # We update test values
    cs = getCipherState(symmetricState)
    ck = getChainingKey(symmetricState)

    ########################################
    # mixKeyAndHash
    ########################################

    # We generate random input key material and we execute mixKeyAndHash
    inputKeyMaterial = randomChaChaPolyKey(rng[])
    mixKeyAndHash(symmetricState, inputKeyMaterial)

    # mixKeyAndHash executes a mixKey and a mixHash using the input key material
    # All Symmetric State's fields are updated
    check:
      cs != getCipherState(symmetricState)
      ck != getChainingKey(symmetricState)
      h != getHandshakeHash(symmetricState)

    # We update test values
    cs = getCipherState(symmetricState)
    ck = getChainingKey(symmetricState)
    h = getHandshakeHash(symmetricState)

    ########################################
    # encryptAndHash and decryptAndHash
    ########################################

    # We store the initial symmetricState in order to correctly perform decryption
    var initialSymmetricState = symmetricState

    # We generate random plaintext and we execute encryptAndHash
    var plaintext = randomChaChaPolyKey(rng[])
    var nonce = getNonce(getCipherState(symmetricState))
    var ciphertext = encryptAndHash(symmetricState, plaintext)

    # encryptAndHash combines encryptWithAd and mixHash over the ciphertext (encryption increases the nonce of the embedded Cipher State but does not change its key)
    # We check if only the handshake hash value and the Symmetric State changed accordingly
    check:
      cs != getCipherState(symmetricState)
      getKey(cs) == getKey(getCipherState(symmetricState))
      getNonce(getCipherState(symmetricState)) == nonce + 1
      ck == getChainingKey(symmetricState)
      h != getHandshakeHash(symmetricState)

    # We restore the symmetric State to its initial value to test decryption
    symmetricState = initialSymmetricState
    
    # We execute decryptAndHash over the ciphertext
    var decrypted = decryptAndHash(symmetricState, ciphertext)

    # decryptAndHash combines decryptWithAd and mixHash over the ciphertext (encryption increases the nonce of the embedded Cipher State but does not change its key)
    # We check if only the handshake hash value and the Symmetric State changed accordingly
    # We further check if decryption corresponds to the original plaintext
    check:
      cs != getCipherState(symmetricState)
      getKey(cs) == getKey(getCipherState(symmetricState))
      getNonce(getCipherState(symmetricState)) == nonce + 1
      ck == getChainingKey(symmetricState)
      h != getHandshakeHash(symmetricState)
      decrypted == plaintext

    ########################################
    # split
    ########################################

    # If at least one mixKey is executed (as above), ck is non-empty
    check:
      getChainingKey(symmetricState) != EmptyKey

    # When a Symmetric State's ck is non-empty, we can execute split, which creates two distinct Cipher States cs1 and cs2 
    # with non-empty encryption keys and nonce set to 0
    var (cs1, cs2) = split(symmetricState)

    check:
      getKey(cs1) != EmptyKey
      getKey(cs2) != EmptyKey
      getNonce(cs1) == 0.uint64
      getNonce(cs2) == 0.uint64
      getKey(cs1) != getKey(cs2)
