{.used.}

import std/[times, random], stew/byteutils, testutils/unittests, nimcrypto
import ../../../waku/waku_core, ../../../waku/waku_archive/driver/queue_driver/index

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
    smallIndex1 = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    smallIndex2 = IndexV2(
      digest: hashFromStr("1234567"), # digest is less significant than senderTime
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    largeIndex1 = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(9000),
      hash: randomHash(),
    ) # only senderTime differ from smallIndex1
    largeIndex2 = IndexV2(
      digest: hashFromStr("12345"), # only digest differs from smallIndex1
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      hash: randomHash(),
    )
    eqIndex1 = IndexV2(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    eqIndex2 = IndexV2(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    eqIndex3 = IndexV2(
      digest: hashFromStr("0003"),
      receiverTime: getNanosecondTime(9999),
        # receiverTime difference should have no effect on comparisons
      senderTime: getNanosecondTime(54321),
      hash: randomHash(),
    )
    diffPsTopic = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(0),
      senderTime: getNanosecondTime(1000),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime1 = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(1100),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime2 = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(10000),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )
    noSenderTime3 = IndexV2(
      digest: hashFromStr("1234"),
      receiverTime: getNanosecondTime(1200),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "aaaa",
      hash: randomHash(),
    )
    noSenderTime4 = IndexV2(
      digest: hashFromStr("0"),
      receiverTime: getNanosecondTime(1200),
      senderTime: getNanosecondTime(0),
      pubsubTopic: "zzzz",
      hash: randomHash(),
    )

  test "IndexV2 comparison":
    # IndexV2 comparison with senderTime diff
    check:
      cmp(smallIndex1, largeIndex1) < 0
      cmp(smallIndex2, largeIndex1) < 0

    # IndexV2 comparison with digest diff
    check:
      cmp(smallIndex1, smallIndex2) < 0
      cmp(smallIndex1, largeIndex2) < 0
      cmp(smallIndex2, largeIndex2) > 0
      cmp(largeIndex1, largeIndex2) > 0

    # IndexV2 comparison when equal
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

  test "IndexV2 equality":
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

  test "IndexV2 computation should not be empty":
    ## Given
    let ts = getTestTimestamp()
    let wm = WakuMessage(payload: @[byte 1, 2, 3], timestamp: ts)

    ## When
    let ts2 = getTestTimestamp() + 10
    let index = IndexV2.compute(wm, ts2, DefaultContentTopic)

    ## Then
    check:
      index.digest.data.len != 0
      index.digest.data.len == 32 # sha2 output length in bytes
      index.receiverTime == ts2 # the receiver timestamp should be a non-zero value
      index.senderTime == ts
      index.pubsubTopic == DefaultContentTopic

  test "IndexV2 digest of two identical messsage should be the same":
    ## Given
    let topic = ContentTopic("test-content-topic")
    let
      wm1 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)
      wm2 = WakuMessage(payload: @[byte 1, 2, 3], contentTopic: topic)

    ## When
    let ts = getTestTimestamp()
    let
      index1 = IndexV2.compute(wm1, ts, DefaultPubsubTopic)
      index2 = IndexV2.compute(wm2, ts, DefaultPubsubTopic)

    ## Then
    check:
      index1.digest == index2.digest
