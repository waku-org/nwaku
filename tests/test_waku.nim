{.used.}

import chronos, testutils/unittests, std/options

import waku

suite "Waku API":
  asyncTest "Create a node":
    let config = LibWakuConfig(
      mode: WakuMode.Relay, networkConfig: some(NetworkConfig(clusterId: 42))
    )

    let node = (await createNode(config)).valueOr:
      raiseAssert error
