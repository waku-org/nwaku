{.used.}

import
  testutils/unittests,
  ../../waku/v2/protocol/waku_noise/noise,
  ../test_helpers


procSuite "Waku Noise":
  
  let rng = rng()

  test "ChaChaPoly Encryption/Decryption":

    let cipherState = randomChaChaPolyCipherState(rng[])

    let
      plaintext: seq[byte] = randomSeqByte(rng[], 128)
      ciphertext: ChaChaPolyCiphertext = encrypt(cipherState, plaintext)
      decryptedCiphertext: seq[byte] = decrypt(cipherState, ciphertext)

    check: 
      plaintext == decryptedCiphertext