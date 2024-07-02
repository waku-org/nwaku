{.used.}

import std/[times, random], stew/byteutils, testutils/unittests, nimcrypto
import waku/waku_core, waku/waku_archive/driver/queue_driver/index

var rng = initRand()

## Helpers

proc getTestTimestamp(offset = 0): Timestamp =
  let now = getNanosecondTime(epochTime() + float(offset))
  Timestamp(now)

proc hashFromStr(input: string): MDigest[256] =
  var ctx: sha256

  ctx.init()
  ctx.update(input.toBytes())
  let hashed = ctx.finish()
  ctx.clear()

  return hashed

proc randomHash(): WakuMessageHash =
  var hash: WakuMessageHash

  for i in 0 ..< hash.len:
    let numb: byte = byte(rng.next())
    hash[i] = numb

  hash

suite "Queue Driver - index":
  ## Test vars
  let
    smallIndex1 = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    smallIndex2 = Index(
      digest: hashFromStr("1234567"), # digest is less significant than senderTime
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    largeIndex1 = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(9000),
      hash: randomHash(),
    ) # only senderTime differ from smallIndex1
    largeIndex2 = Index(
      digest: hashFromStr("12345"), # only digest differs from smallIndex1
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    eqIndex1 = Index(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    eqIndex2 = Index(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    eqIndex3 = Index(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(9999),
        # receiverTime difference should have no effect on comparisons
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    diffPsTopic = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime1 = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(1100),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime2 = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(10000),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime3 = Index(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(1200),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "aaaa",
      hash: randomHash(),
    )
    noSenderTime4 = Index(
      digest: hashFromStr("0"),
      receiverTime: getNanosecondTime(1200),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )

  test "Index comparison":
    # Index comparison with senderTime diff
    check:
      cmp(smallIndex1, largeIndex1) < 0
      cmp(smallIndex2, largeIndex1) < 0

    # Index comparison with digest diff
    check:
      cmp(smallIndex1, smallIndex2) < 0
      cmp(smallIndex1, largeIndex2) < 0
      cmp(smallIndex2, largeIndex2) > 0
      cmp(largeIndex1, largeIndex2) > 0

    # Index comparison when equal
    check:
      cmp(eqIndex1, eqIndex2) == 0

    # pubsubTopic difference
    check:
      cmp(smallIndex1, diffPsTopic) < 0

    # receiverTime diff plays no role when senderTime set
    check:
      cmp(eqIndex1, eqIndex3) == 0

    # receiverTime diff plays no role when digest/pubsubTopic equal
    check:
      cmp(noSenderTime1, noSenderTime2) == 0

    # sort on receiverTime with no senderTimestamp and unequal pubsubTopic
    check:
      cmp(noSenderTime1, noSenderTime3) < 0

    # sort on receiverTime with no senderTimestamp and unequal digest
    check:
      cmp(noSenderTime1, noSenderTime4) < 0

    # sort on receiverTime if no senderTimestamp on only one side
    check:
      cmp(smallIndex1, noSenderTime1) < 0
      cmp(noSenderTime1, smallIndex1) > 0 # Test symmetry
      cmp(noSenderTime2, eqIndex3) < 0
      cmp(eqIndex3, noSenderTime2) > 0 # Test symmetry

  test "Index equality":
    # Exactly equal
    check:
      eqIndex1 == eqIndex2

    # Receiver time plays no role, even without sender time
    check:
      eqIndex1 == eqIndex3
      noSenderTime1 == noSenderTime2 # only receiver time differs, indices are equal
      noSenderTime1 != noSenderTime3 # pubsubTopics differ
      noSenderTime1 != noSenderTime4 # digests differ

    # Unequal sender time
    check:
      smallIndex1 != largeIndex1

    # Unequal digest
    check:
      smallIndex1 != smallIndex2

    # Unequal hash and digest
    check:
      smallIndex1 != eqIndex1

    # Unequal pubsubTopic
    check:
      smallIndex1 != diffPsTopic

  test "Index computation should not be empty":
    ## Given
    let ts = getTestTimestamp()
    let wm = WakuMessage(payload: @[byte 1, 2, 3], timestamp: ts)

    ## When
    let ts2 = getTestTimestamp() + 10
    let index = Index.compute(wm, ts2, DefaultContentTopic)

    ## Then
    check:
      index.digest.data.len != 0
      index.digest.data.len == 32 # sha2 output length in bytes
      index.receiverTime == ts2 # the receiver timestamp should be a non-zero value
      index.senderTime == ts
      index.pubsubTopic == DefaultContentTopic

  test "Index digest of two identical messsage should be the same":
    ## Given
    let topic = ContentTopic("test-content-topic")
    let
      wm1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)

    ## When
    let ts = getTestTimestamp()
    let
      index1 = Index.compute(wm1, ts, DefaultPubsubTopic)
      index2 = Index.compute(wm2, ts, DefaultPubsubTopic)

    ## Then
    check:
      index1.digest == index2.digest
