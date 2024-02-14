{.used.}

import 
  testutils/unittests,
  chronos,
  os
import 
  ../../../waku/waku_rln_relay/nonce_manager


suite "Nonce manager":
  test "should initialize successfully":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    
    check:
      nm.nonceLimit == 100.uint
      nm.nextNonce == 0.uint

  test "should generate a new nonce":
    let nm = NonceManager.init(nonceLimit = 100.uint)
    let nonceRes = nm.get()

    assert nonceRes.isOk(), $nonceRes.error
    
    check:
      nonceRes.get() == 0.uint
      nm.nextNonce == 1.uint

  test "should fail to generate a new nonce if limit is reached":
    let nm = NonceManager.init(nonceLimit = 1.uint)
    let nonceRes = nm.get()
    let nonceRes2 = nm.get()

    assert nonceRes.isOk(), $nonceRes.error
    assert nonceRes2.isErr(), "Expected error, got: " & $nonceRes2.value

    check:
      nonceRes2.error.kind == NonceManagerErrorKind.NonceLimitReached

  test "should generate a new nonce if epoch is crossed":
    let nm = NonceManager.init(nonceLimit = 1.uint, epoch = float(0.000001))
    let nonceRes = nm.get()
    sleep(1)
    let nonceRes2 = nm.get()

    assert nonceRes.isOk(), $nonceRes.error
    assert nonceRes2.isOk(), $nonceRes2.error

    check:
      nonceRes.value == 0.uint
      nonceRes2.value == 0.uint