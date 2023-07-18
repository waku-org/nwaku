## Waku autosharding utils
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  nimcrypto,
  std/math,
  std/sequtils,
  std/algorithm,
  std/strutils,
  stew/endians2,
  stew/results

import
  ./content_topic,
  ./pubsub_topic

const ClusterIndex = 0
const GenerationZeroShardsCount = 5

type ShardsPriority = seq[(NsPubsubTopic, float64)]

proc applyWeight(hashValue: uint64, weight: float64): float64 =
  -weight / math.ln(float64(hashValue) / float64(high(uint64)))

proc hashOrder(x, y: (NsPubsubTopic, float64)): int =
    cmp(x[1], y[1])

proc weightedShardList(topic: NsContentTopic, shardCount: int, weights: seq[float64]): Result[ShardsPriority, string] =
  ## Returns the ordered list of shards and their priority values.

  if weights.len != shardCount:
    return err("Must provide weights for every shards")

  let shardsNWeights = zip(toSeq(0..shardCount), weights)

  var list = newSeq[(NsPubsubTopic, float64)](shardCount)

  for (shard, weight) in shardsNWeights:
    let pubsub = NsPubsubTopic.staticSharding(ClusterIndex, uint16(shard))

    let hash = sha256.digest($topic & $pubsub)
    let hashValue = uint64.fromBytesBE(hash.data)
    let value = applyWeight(hashValue, weight)

    list[shard] = (pubsub, value)

  list.sort(hashOrder)

  ok(list)

type ShardingBias = enum
  None = "none"
  Kanonymity = "anon"
  Throughput = "bandwidth"

proc shardingParam(topic: NsContentTopic): Result[(int, ShardingBias), string] =
  ## Returns the total shard count and the sharding selection bias
  ## from the content topic.
  let gen = try:
    parseInt(topic.generation)
  except ValueError:
    return err("Cannot parse generation: " & getCurrentExceptionMsg())

  let shardCount =
    case gen:
      of 0:
        GenerationZeroShardsCount
      else:
        return err("Generation > 0 are not supported yet")

  let bias = try:
    parseEnum[ShardingBias](topic.bias)
  except ValueError:
    return err("Cannot parse sharding bias: " & getCurrentExceptionMsg())

  ok((shardCount, bias))

proc biasedWeights(shardCount: int, bias: ShardingBias): seq[float64] =
  var weights = newSeq[1.0](shardCount)

  case bias:
    of None:
      return weights
    of Kanonymity:
      # we choose the lower 20% of shards and double their weigths
      let index = shardCount div 5
      for i in (0..<index):
        weights[i] *= 2.0
    of Throughput:
      # we choose the higher 80% of shards and double their weigths
      let index = shardCount div 5
      for i in (index..<shardCount):
        weights[i] *= 2.0

  weights

proc singleHighestWeigthShard*(topic: NsContentTopic): Result[NsPubsubTopic, string] =
  let (count, bias) = ? shardingParam(topic)

  let weights = biasedWeights(count, bias)

  let list = ? weightedShardList(topic, count, weights)

  let (pubsub, _) = list[list.len - 1]

  ok(pubsub)
