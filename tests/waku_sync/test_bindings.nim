{.used.}

import std/[options], testutils/unittests, chronos, libp2p/crypto/crypto, std/random

import
  ../../waku/
    [node/peer_manager, waku_core, waku_core/message/digest, waku_sync/raw_bindings],
  ../testlib/[wakucore],
  ./sync_utils

random.randomize()

#TODO clean this up

suite "Bindings":
  var storage {.threadvar.}: NegentropyStorage
  var messages {.threadvar.}: seq[(WakuMessageHash, WakuMessage)]

  setup:
    let storageRes = NegentropyStorage.new()
    assert storageRes.isOk(), $storageRes.error
    storage = storageRes.get()

    messages = @[]
    for _ in 0 ..< 10:
      let msg = fakeWakuMessage()
      let hash = computeMessageHash(DefaultPubsubTopic, msg)
      messages.add((hash, msg))

  teardown:
    storage.delete()

  test "storage insert":
    check:
      storage.len() == 0

    let insRes = storage.insert(messages[0][1].timestamp, messages[0][0])

    assert insRes.isOk(), $insRes.error

    check:
      storage.len() == 1

  test "storage erase":
    let insRes = storage.insert(messages[0][1].timestamp, messages[0][0])
    assert insRes.isOk(), $insRes.error

    check:
      storage.len() == 1

    var delRes = storage.erase(messages[0][1].timestamp, messages[0][0])
    assert delRes.isOk()

    check:
      storage.len() == 0

    delRes = storage.erase(messages[0][1].timestamp, messages[0][0])
    assert delRes.isErr()

    check:
      storage.len() == 0

  test "subrange":
    for (hash, msg) in messages:
      let insRes = storage.insert(msg.timestamp, hash)
      assert insRes.isOk(), $insRes.error

    check:
      storage.len() == 10

    let subrangeRes = NegentropySubRangeStorage.new(storage)
    assert subrangeRes.isOk(), subrangeRes.error
    let subrange = subrangeRes.get()

    check:
      subrange.len() == 10

  #[ test "storage memory size":
    for (hash, msg) in messages:
      let insRes = storage.insert(msg.timestamp, hash)
      assert insRes.isOk(), $insRes.error

    check:
      storage.len() == 10

    for (hash, msg) in messages:
      let delRes = storage.erase(msg.timestamp, hash)
      assert delRes.isOk(), $delRes.error

    check:
      storage.len() == 0

    #TODO validate that the occupied memory didn't grow. ]#

  test "reconcile server differences":
    for (hash, msg) in messages:
      let insRes = storage.insert(msg.timestamp, hash)
      assert insRes.isOk(), $insRes.error

    let clientNegentropyRes = Negentropy.new(storage, 0)

    let storageRes = NegentropyStorage.new()
    assert storageRes.isOk(), $storageRes.error
    let serverStorage = storageRes.get()

    for (hash, msg) in messages:
      let insRes = serverStorage.insert(msg.timestamp, hash)
      assert insRes.isOk(), $insRes.error

    # the extra msg
    let msg = fakeWakuMessage()
    let hash = computeMessageHash(DefaultPubsubTopic, msg)
    let insRes = serverStorage.insert(msg.timestamp, hash)
    assert insRes.isOk(), $insRes.error

    let serverNegentropyRes = Negentropy.new(serverStorage, 0)

    assert clientNegentropyRes.isOk(), $clientNegentropyRes.error
    assert serverNegentropyRes.isOk(), $serverNegentropyRes.error

    let clientNegentropy = clientNegentropyRes.get()
    let serverNegentropy = serverNegentropyRes.get()

    let initRes = clientNegentropy.initiate()
    assert initRes.isOk(), $initRes.error
    let init = initRes.get()

    let reconRes = serverNegentropy.serverReconcile(init)
    assert reconRes.isOk(), $reconRes.error
    let srecon = reconRes.get()

    var
      haves: seq[WakuMessageHash]
      needs: seq[WakuMessageHash]
    let creconRes = clientNegentropy.clientReconcile(srecon, haves, needs)
    assert creconRes.isOk(), $creconRes.error
    let reconOpt = creconRes.get()

    check:
      reconOpt.isNone()
      needs[0] == hash
