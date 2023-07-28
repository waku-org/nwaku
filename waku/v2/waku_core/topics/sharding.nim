## Waku autosharding utils
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  nimcrypto,
  std/options,
  std/math,
  std/sequtils,
  std/algorithm,
  stew/endians2,
  stew/results,
  stew/byteutils

import
  ./content_topic,
  ./pubsub_topic

## For indices allocation and other magic numbers refer to RFC 51
const ClusterIndex* = 49152
const GenerationZeroShardsCount* = 5

type ShardsPriority = seq[tuple[topic: NsPubsubTopic, value: float64]]

proc shardCount*(topic: NsContentTopic): Result[int, string] =
  ## Returns the total shard count, sharding selection bias
  ## and the shard name from the content topic.
  let shardCount =
    if topic.generation.isNone():
      ## Implicit generation # is 0 for all content topic
      GenerationZeroShardsCount
    else:
      case topic.generation.get():
        of 0:
          GenerationZeroShardsCount
        else:
          return err("Generation > 0 are not supported yet")

  ok((shardCount))

proc biasedWeights*(shardCount: int, bias: ShardingBias): seq[float64] =
  var weights = repeat(1.0, shardCount)

  case bias:
    of Unbiased:
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

proc applyWeight(hashValue: uint64, weight: float64): float64 =
  (-weight) / math.ln(float64(hashValue) / float64(high(uint64)))

proc hashOrder*(x, y: (NsPubsubTopic, float64)): int =
    cmp(x[1], y[1])

proc weightedShardList*(topic: NsContentTopic, shardCount: int, weightList: seq[float64]): Result[ShardsPriority, string] =
  ## Returns the ordered list of shards and their priority values.
  if weightList.len < shardCount:
    return err("Must provide weights for every shards")

  let shardsNWeights = zip(toSeq(0..shardCount), weightList)

  var list = newSeq[(NsPubsubTopic, float64)](shardCount)

  for (shard, weight) in shardsNWeights:
    let pubsub = NsPubsubTopic.staticSharding(ClusterIndex, uint16(shard))

    let clusterBytes = toBytesBE(uint16(ClusterIndex))
    let shardBytes = toBytesBE(uint16(shard))
    let bytes = toBytes(topic.application) & toBytes(topic.version) & @clusterBytes & @shardBytes
    let hash = sha256.digest(bytes)
    let hashValue = uint64.fromBytesBE(hash.data)
    let value = applyWeight(hashValue, weight)

    list[shard] = (pubsub, value)

  list.sort(hashOrder)

  ok(list)

proc singleHighestWeigthShard*(topic: NsContentTopic): Result[NsPubsubTopic, string] =
  let count = ? shardCount(topic)

  let weights = biasedWeights(count, topic.bias)

  let list = ? weightedShardList(topic, count, weights)

  let (pubsub, _) = list[list.len - 1]

  ok(pubsub)
