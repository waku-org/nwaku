{.used.}

import testutils/unittests
import common/envvar_serialization/utils

suite "nim-envvar-serialization - utils":
  test "construct env var key":
    ## Given
    let prefix = "some-prefix"
    let name = @["db-url"]

    ## When
    let key = constructKey(prefix, name)

    ## Then
    check:
      key == "SOME_PREFIX_DB_URL"
