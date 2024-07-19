{.used.}

import std/options, testutils/unittests, chronos

import
  waku/[node/peer_manager, waku_core, waku_store/resume],
  ../testlib/[wakucore, testasync],
  ./store_utils

suite "Store Resume":
  var resume {.threadvar.}: StoreResume

  asyncSetup:
    resume = StoreResume.new().expect("Valid Store Resume")

    resume.start()

  asyncTeardown:
    await resume.stopWait()

  asyncTest "get set roundtrip":
    let ts = getNowInNanosecondTime()

    let setRes = resume.setLastOnlineTimestamp(ts)
    assert setRes.isOk(), $setRes.error

    let getRes = resume.getLastOnlineTimestamp()
    assert getRes.isOk(), $getRes.error

    let getTs = getRes.get()

    assert getTs == ts, "wrong timestamp"
