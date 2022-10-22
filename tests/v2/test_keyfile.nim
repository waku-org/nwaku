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

  test "Create/Save/Load keyfile test":

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