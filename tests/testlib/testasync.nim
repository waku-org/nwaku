# Sourced from: vendor/nim-libp2p/tests/testutils.nim
# Adds the ability for asyncSetup and asyncTeardown to be used in unittest2

template asyncTeardown*(body: untyped): untyped =
  teardown:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

template asyncSetup*(body: untyped): untyped =
  setup:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())
