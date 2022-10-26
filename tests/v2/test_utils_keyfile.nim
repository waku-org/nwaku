{.used.}

import
  std/[json, os],
  testutils/unittests, chronos, chronicles,
  eth/keys
import
  ../../waku/v2/utils/keyfile,
  ../test_helpers

from ../../waku/v2/protocol/waku_noise/noise_utils import randomSeqByte

suite "KeyFile test suite":

  let rng = newRng()

  test "Create/Save/Load single keyfile":

    # The password we use to encrypt our secret
    let password = "randompassword"

    # The filepath were the keyfile will be stored
    let filepath = "./test.keyfile"
    defer: removeFile(filepath)

    # The secret
    var secret = randomSeqByte(rng[], 300)

    # We create a keyfile encrypting the secret with password
    let keyfile = createKeyFileJson(secret, password)

    check:
      keyfile.isOk()
      # We save to disk the keyfile
      saveKeyFile(filepath, keyfile.get()).isOk()

    # We load from the file all the decrypted keyfiles encrypted under password
    var decodedKeyfiles = loadKeyFile(filepath, password)

    check:
      decodedKeyfiles.isOk()
      # Since only one secret was stored in file, we expect only one keyfile being decrypted
      decodedKeyfiles.get().len == 1

    # We check if the decrypted secret is the same as the original secret
    let decodedSecret = decodedKeyfiles.get()[0]

    check:
      secret == decodedSecret.get()

  test "Create/Save/Load multiple keyfiles in same file":

    # We set different passwords for different keyfiles that will be stored in same file
    let password1 = "password1"
    let password2 = ""
    let password3 = "password3"
    var keyfile: KfResult[JsonNode] 

    let filepath = "./test.keyfile"
    defer: removeFile(filepath)

    # We generate 6 different secrets and we encrypt them using 3 different passwords, and we store the obtained keystore

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

    # We encrypt secret6 with password1
    let secret6 = randomSeqByte(rng[], 300)
    keyfile = createKeyFileJson(secret6, password1)
    check:
      keyfile.isOk()
      saveKeyFile(filepath, keyfile.get()).isOk()

    # Now there are 6 keyfiles stored in filepath encrypted with 3 different passwords
    # We decrypt the keyfiles using the respective passwords and we check that the number of 
    # successful decryptions corresponds to the number of secrets encrypted under that password

    var decodedKeyfilesPassword1 = loadKeyFile(filepath, password1)
    check:
      decodedKeyfilesPassword1.isOk()
      decodedKeyfilesPassword1.get().len == 3
    var decodedSecretsPassword1 = decodedKeyfilesPassword1.get()

    var decodedKeyfilesPassword2 = loadKeyFile(filepath, password2)
    check:
      decodedKeyfilesPassword2.isOk()
      decodedKeyfilesPassword2.get().len == 1
    var decodedSecretsPassword2 = decodedKeyfilesPassword2.get()

    var decodedKeyfilesPassword3 = loadKeyFile(filepath, password3)
    check:
      decodedKeyfilesPassword3.isOk()
      decodedKeyfilesPassword3.get().len == 2
    var decodedSecretsPassword3 = decodedKeyfilesPassword3.get()
    
    # We check if the corresponding secrets are correct
    check:
      # Secrets encrypted with password 1
      secret1 == decodedSecretsPassword1[0].get()
      secret5 == decodedSecretsPassword1[1].get()
      secret6 == decodedSecretsPassword1[2].get()
      # Secrets encrypted with password 2
      secret2 == decodedSecretsPassword2[0].get()
      # Secrets encrypted with password 3
      secret3 == decodedSecretsPassword3[0].get()
      secret4 == decodedSecretsPassword3[1].get()