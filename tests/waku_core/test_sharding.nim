{.used.}

import
  std/options,
  std/strutils,
  std/sugar,
  std/algorithm,
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

    NsContentTopic.init(none(int), Unbiased, app, version, name, enc)

  test "Implicit content topic generation":
    ## Given
    let topic = "/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardCount(ns)

    ## Then
    assert paramRes.isOk(), paramRes.error

    let count = paramRes.get()
    check:
      count == GenerationZeroShardsCount
      ns.bias == Unbiased

  test "Valid content topic":
    ## Given
    let topic = "/0/lower20/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardCount(ns)

    ## Then
    assert paramRes.isOk(), paramRes.error

    let count = paramRes.get()
    check:
      count == GenerationZeroShardsCount
      ns.bias == Lower20

  test "Invalid content topic generation":
    ## Given
    let topic = "/1/unbiased/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardCount(ns)

    ## Then
    assert paramRes.isErr(), $paramRes.get()

    let err = paramRes.error
    check:
      err == "Generation > 0 are not supported yet"

  test "Weigths bias":
    ## Given
    let count = 5

    ## When
    let anonWeigths = biasedWeights(count, ShardingBias.Lower20)
    let speedWeigths = biasedWeights(count, ShardingBias.Higher80)

    ## Then
    check:
      anonWeigths[0] == 2.0
      anonWeigths[1] == 1.0
      anonWeigths[2] == 1.0
      anonWeigths[3] == 1.0
      anonWeigths[4] == 1.0

      speedWeigths[0] == 1.0
      speedWeigths[1] == 2.0
      speedWeigths[2] == 2.0
      speedWeigths[3] == 2.0
      speedWeigths[4] == 2.0

  test "Sorted shard list":
    ## Given
    let topic = "/0/unbiased/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")
    let count = shardCount(contentTopic).expect("Valid parameters")
    let weights = biasedWeights(count, contentTopic.bias)

    let shardsRes = weightedShardList(contentTopic, count, weights)

    ## Then
    assert shardsRes.isOk(), shardsRes.error

    let shards = shardsRes.get()
    check:
      shards.len == count
      isSorted(shards, hashOrder)

  test "Shard Choice Reproducibility":
    ## Given
    let topic = "/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")

    let res = singleHighestWeigthShard(contentTopic)

    ## Then
    assert res.isOk(), res.error

    let pubsubTopic = res.get()

    check:
      pubsubTopic == NsPubsubTopic.staticSharding(ClusterIndex, 3)

  test "Shard Choice Simulation":
    ## Given
    let topics = collect:
      for i in 0..<100000:
        randomContentTopic()

    var counts = newSeq[0](GenerationZeroShardsCount)

    ## When
    for topic in topics:
      let pubsub = singleHighestWeigthShard(topic).expect("Valid Topic")
      counts[pubsub.shard] += 1

    ## Then
    for i in 1..<GenerationZeroShardsCount:
      check:
        float64(counts[i - 1]) <= (float64(counts[i]) * 1.05)
        float64(counts[i]) <= (float64(counts[i - 1]) * 1.05)
        float64(counts[i - 1]) >= (float64(counts[i]) * 0.95)
        float64(counts[i]) >= (float64(counts[i - 1]) * 0.95)

    #echo counts










