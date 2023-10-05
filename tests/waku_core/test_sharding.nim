{.used.}

import
  std/options,
  std/strutils,
  std/sugar,
  std/random,
  stew/results,
  testutils/unittests
import
  ../../../waku/waku_core/topics

suite "Waku Sharding":

  randomize()

  const WordLength = 5

  proc randomContentTopic(): NsContentTopic =
    var app = ""

    for n in 0..<WordLength:
      let letter = sample(Letters)
      app.add(letter)

    let version = "1"

    var name = ""

    for n in 0..<WordLength:
      let letter = sample(Letters)
      name.add(letter)

    let enc = "cbor"

    NsContentTopic.init(none(int), app, version, name, enc)

  test "Implicit content topic generation":
    ## Given
    let topic = "/toychat/2/huilong/proto"

    ## When
    let parseRes = NsContentTopic.parse(topic)

    ## Then
    assert parseRes.isOk(), $parseRes.error

    let nsTopic = parseRes.get()
    check:
      nsTopic.generation == none(int)

  test "Valid content topic":
    ## Given
    let topic = "/0/toychat/2/huilong/proto"

    ## When
    let parseRes = NsContentTopic.parse(topic)

    ## Then
    assert parseRes.isOk(), $parseRes.error

    let nsTopic = parseRes.get()
    check:
      nsTopic.generation.get() == 0

  test "Invalid content topic generation":
    ## Given
    let topic = "/1/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let shardRes = getShard(ns)

    ## Then
    assert shardRes.isErr(), $shardRes.get()

    let err = shardRes.error
    check:
      err == "Generation > 0 are not supported yet"

  #[ test "Sorted shard list":
    ## Given
    let topic = "/0/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")
    let count = shardCount(contentTopic).expect("Valid parameters")
    let weights = repeat(1.0, count)

    let shardsRes = weightedShardList(contentTopic, count, weights)

    ## Then
    assert shardsRes.isOk(), shardsRes.error

    let shards = shardsRes.get()
    check:
      shards.len == count
      isSorted(shards, hashOrder) ]#

  test "Shard Choice Reproducibility":
    ## Given
    let topic = "/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")

    let pubsub = getGenZeroShard(contentTopic, GenerationZeroShardsCount)

    ## Then
    check:
      pubsub == NsPubsubTopic.staticSharding(ClusterId, 3)

  test "Shard Choice Simulation":
    ## Given
    let topics = collect:
      for i in 0..<100000:
        randomContentTopic()

    var counts = newSeq[0](GenerationZeroShardsCount)

    ## When
    for topic in topics:
      let pubsub = getShard(topic).expect("Valid Topic")
      counts[pubsub.shard] += 1

    ## Then
    for i in 1..<GenerationZeroShardsCount:
      check:
        float64(counts[i - 1]) <= (float64(counts[i]) * 1.05)
        float64(counts[i]) <= (float64(counts[i - 1]) * 1.05)
        float64(counts[i - 1]) >= (float64(counts[i]) * 0.95)
        float64(counts[i]) >= (float64(counts[i - 1]) * 0.95)

    #echo counts










