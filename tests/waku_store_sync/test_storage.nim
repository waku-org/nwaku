{.used.}

import std/[options, random], testutils/unittests, chronos

import
  ../../waku/waku_core,
  ../../waku/waku_core/message/digest,
  ../../waku/waku_store_sync,
  ../../waku/waku_store_sync/storage/seq_storage,
  ./sync_utils

suite "Waku Sync Storage":
  test "process fingerprint range":
    var rng = initRand()
    let count = 10_000
    var elements = newSeqOfCap[ID](count)

    for i in 0 ..< count:
      let id = ID(time: Timestamp(i), fingerprint: randomHash(rng))

      elements.add(id)

    var storage1 = SeqStorage.new(elements)
    var storage2 = SeqStorage.new(elements)

    let lb = elements[0]
    let ub = elements[count - 1]
    let bounds = lb .. ub
    let fingerprint1 = storage1.fingerprinting(bounds)

    var outputPayload: SyncPayload

    storage2.processFingerprintRange(bounds, fingerprint1, outputPayload)

    let expected = SyncPayload(
      ranges: @[(bounds, RangeType.skipRange)], fingerprints: @[], itemSets: @[]
    )

    check:
      outputPayload == expected

  test "process item set range":
    var rng = initRand()
    let count = 1000
    var elements1 = newSeqOfCap[ID](count)
    var elements2 = newSeqOfCap[ID](count)
    var diffs: seq[Fingerprint]

    for i in 0 ..< count:
      let id = ID(time: Timestamp(i), fingerprint: randomHash(rng))

      elements1.add(id)
      if rng.rand(0 .. 9) == 0:
        elements2.add(id)
      else:
        diffs.add(id.fingerprint)

    var storage1 = SeqStorage.new(elements1)

    let lb = elements1[0]
    let ub = elements1[count - 1]
    let bounds = lb .. ub

    let itemSet2 = ItemSet(elements: elements2, reconciled: true)

    var
      toSend: seq[Fingerprint]
      toRecv: seq[Fingerprint]
      outputPayload: SyncPayload

    storage1.processItemSetRange(bounds, itemSet2, toSend, toRecv, outputPayload)

    check:
      toSend == diffs

  ## disabled tests are rough benchmark 
  #[ test "10M fingerprint":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[ID](count)

    for i in 0 .. count:
      let id = ID(time: Timestamp(i), fingerprint: randomHash(rng))

      elements.add(id)

    let storage = SeqStorage.new(elements)

    let before = getMonoTime()

    discard storage.fingerprinting(some(0 .. count))

    let after = getMonoTime()

    echo "Fingerprint Time: " & $(after - before) ]#

  #[ test "random inserts":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[ID](count)

    for i in 0 .. count:
      let id = ID(time: Timestamp(i), fingerprint: randomHash(rng))

      elements.add(id)

    var storage = SeqStorage.new(elements)

    var avg: times.Duration
    for i in 0 ..< 1000:
      let newId =
        ID(time: Timestamp(rng.rand(0 .. count)), fingerprint: randomHash(rng))

      let before = getMonoTime()

      discard storage.insert(newId)

      let after = getMonoTime()

      avg += after - before

    avg = avg div 1000

    echo "Avg Time 1K Inserts: " & $avg ]#

  #[ test "trim":
    var rng = initRand()

    let count = 10_000_000

    var elements = newSeqOfCap[ID](count)

    for i in 0 .. count:
      let id = ID(time: Timestamp(i), fingerprint: randomHash(rng))

      elements.add(id)

    var storage = SeqStorage.new(elements)

    let before = getMonoTime()

    discard storage.trim(Timestamp(count div 4))

    let after = getMonoTime()

    echo "Trim Time: " & $(after - before) ]#
