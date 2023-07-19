{.used.}

import
  std/strutils,
  std/sequtils,
  std/sugar,
  std/algorithm,
  std/random,
  stew/results,
  testutils/unittests
import
  ../../../waku/v2/waku_core/topics

suite "Waku Sharding":

  randomize()

  const WordLength = 5

  proc randomContentTopic(): NsContentTopic =
    let gen = "0"
    let bias = "none"

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

    NsContentTopic.init(gen, bias, app, version, name, enc)


  test "Valid generation & sharding bias":
    ## Given
    let topic = "/0/none/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardingParam(ns)

    ## Then
    check paramRes.isOk()

    let (count, bias) = paramRes.get()
    check:
      count == GenerationZeroShardsCount
      bias == ShardingBias.None

  test "Invalid generation":
    ## Given
    let topic = "/1/none/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardingParam(ns)

    ## Then
    check paramRes.isErr()
    let err = paramRes.tryError()
    check:
      err == "Generation > 0 are not supported yet"

  test "Invalid bias":
    ## Given
    let topic = "/0/kanonymity/toychat/2/huilong/proto"

    ## When
    let ns = NsContentTopic.parse(topic).expect("Parsing")

    let paramRes = shardingParam(ns)

    ## Then
    check paramRes.isErr()
    let err = paramRes.tryError()
    check:
      err.startsWith("Cannot parse sharding bias: ")

  test "Weigths bias":
    ## Given
    let count = 5

    ## When
    let anonWeigths = biasedWeights(count, ShardingBias.Kanonymity)
    let speedWeigths = biasedWeights(count, ShardingBias.Throughput)

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
    let topic = "/0/none/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")
    let (count, bias) = shardingParam(contentTopic).expect("Valid parameters")

    let weigths = biasedWeights(count, bias)

    let shardsRes = weightedShardList(contentTopic, count, weigths)

    ## Then
    check shardsRes.isOk()

    let shards = shardsRes.get()
    check:
      shards.len == count
      isSorted(shards, hashOrder)

  test "Shard Choice Reproducibility":
    ## Given
    let topic = "/0/none/toychat/2/huilong/proto"

    ## When
    let contentTopic = NsContentTopic.parse(topic).expect("Parsing")

    let res = singleHighestWeigthShard(contentTopic)

    ## Then
    check res.isOk()

    let pubsubTopic = res.get()

    check:
      pubsubTopic == NsPubsubTopic.staticSharding(ClusterIndex, 2)

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










