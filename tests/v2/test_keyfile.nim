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

  test "Create/Save/Load test":
    var secret = randomSeqByte(rng[], 100)
    let jobject = createKeyFileJson(secret, "randompassword")[]

    check:
      saveKeyFile("test.keyfile", jobject).isOk()
    var decodedSecret = loadKeyFile("test.keyfile", "randompassword")[]
    check:
      secret == decodedSecret
    removeFile("test.keyfile")