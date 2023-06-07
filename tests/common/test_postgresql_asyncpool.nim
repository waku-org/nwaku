{.used.}

import
  std/[strutils, os],
  stew/results,
  testutils/unittests,
  chronos
import
  ../../waku/common/postgres/asyncpool,
  ../../waku/common/postgres/pg_asyncpool_opts

suite "Async pool":

  asyncTest "Create connection pool":
    ## TODO: extend unit tests
    var pgOpts = PgAsyncPoolOptions.init()
