{.used.}

import
  std/[json, os],
  testutils/unittests, chronos, chronicles,
  eth/keys,
  ../../waku/v2/utils/keyfile,
  ../test_helpers

from ../../waku/v2/protocol/waku_noise/noise_utils import randomSeqByte

suite "KeyFile test suite":

  let rng = newRng()

  test "Create/Save/Load single keyfile":

    let password = "randompassword"
    let filepath = "./test.keyfile"

    var secret = randomSeqByte(rng[], 300)
    let keyfile = createKeyFileJson(secret, password)

    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    var decodedSecret = loadKeyFile("test.keyfile", password)

    check:
      decodedSecret.isOk()
      secret == decodedSecret.get()

    removeFile(filepath)

  test "Create/Save/Load multiple keyfiles in same file":

    let password1 = "password1"
    let password2 = "password2"
    let password3 = "password3"
    let filepath = "./test.keyfile"
    var keyfile: KfResult[JsonNode] 

    let secret1 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret1, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    let secret2 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret2, password2)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    let secret3 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret3, password3)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret4 with password3
    let secret4 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret4, password3)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret5 with password1
    let secret5 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret5, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We encrypt secret5 with password1
    let secret6 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret6, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # Now there are 5 keyfiles stored in filepath encrypted with 3 different passwords
    # We decode with the respective passwords

    var decodedSecret1 = loadKeyFile("test.keyfile", password1)
    check:
      decodedSecret1.isOk()
      secret1 == decodedSecret1.get()

    var decodedSecret2 = loadKeyFile("test.keyfile", password2)
    check:
      decodedSecret2.isOk()
      secret2 == decodedSecret2.get()

    var decodedSecret3 = loadKeyFile("test.keyfile", password3)
    check:
      decodedSecret3.isOk()
      secret3 == decodedSecret3.get()
    
    # Since we have 2 keyfiles encrypted with same password3, to obtain the secret we skip the first successful decryption, i.e. the keyfile for secret3
    var decodedSecret4 = loadKeyFile("test.keyfile", password3, skip = 1)
    check:
      decodedSecret4.isOk()
      secret4 == decodedSecret4.get()

    # Since we have 3 keyfiles encrypted with same password1, to obtain the secret we skip the first successful decryption, i.e. the keyfile for secret1
    var decodedSecret5 = loadKeyFile("test.keyfile", password1, skip = 1)
    check:
      decodedSecret5.isOk()
      secret5 == decodedSecret5.get()

    # Since we have 3 keyfiles encrypted with same password1, to obtain the secret we skip the first 2 successful decryptions, i.e. the keyfile for secret1 and secret5
    var decodedSecret6 = loadKeyFile("test.keyfile", password1, skip = 2)
    check:
      decodedSecret6.isOk()
      secret6 == decodedSecret6.get()

    removeFile(filepath)