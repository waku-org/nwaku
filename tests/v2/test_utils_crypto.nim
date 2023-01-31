{.used.}

import
  testutils/unittests
import
  ../../waku/common/crypto

suite "Utils - Crypto":
  
  test "Returns a valid rng":
    let rng = getRng()
    check:
      rng is ref HmacDrbgContext
