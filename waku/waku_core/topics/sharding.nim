## Waku autosharding utils
##
## See 51/WAKU2-RELAY-SHARDING RFC: https://rfc.vac.dev/spec/51/#automatic-sharding

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import nimcrypto, std/options, std/tables, stew/endians2, stew/results, stew/byteutils

import ./content_topic, ./pubsub_topic

type Sharding* = object
  clusterId*: uint16
  # TODO: generations could be stored in a table here
  shardCountGenZero*: uint32

proc new*(T: type Sharding, clusterId: uint16, shardCount: uint32): T =
  return Sharding(clusterId: clusterId, shardCountGenZero: shardCount)

proc getGenZeroShard*(s: Sharding, topic: NsContentTopic, count: int): NsPubsubTopic =
  let bytes = toBytes(topic.application) & toBytes(topic.version)

  let hash = sha256.digest(bytes)

  # We only use the last 64 bits of the hash as having more shards is unlikely.
  let hashValue = uint64.fromBytesBE(hash.data[24 .. 31])

  # This is equilavent to modulo shard count but faster
  let shard = hashValue and uint64((count - 1))

  NsPubsubTopic.staticSharding(s.clusterId, uint16(shard))

proc getShard*(s: Sharding, topic: NsContentTopic): Result[NsPubsubTopic, string] =
  ## Compute the (pubsub topic) shard to use for this content topic.

  if topic.generation.isNone():
    ## Implicit generation # is 0 for all content topic
    return ok(s.getGenZeroShard(topic, int(s.shardCountGenZero)))

  case topic.generation.get()
  of 0:
    return ok(s.getGenZeroShard(topic, int(s.shardCountGenZero)))
  else:
    return err("Generation > 0 are not supported yet")

proc getShard*(s: Sharding, topic: ContentTopic): Result[PubsubTopic, string] =
  let parsedTopic = NsContentTopic.parse(topic).valueOr:
    return err($error)

  let shard = ?s.getShard(parsedTopic)

  ok($shard)

proc parseSharding*(
    s: Sharding,
    pubsubTopic: Option[PubsubTopic],
    contentTopics: ContentTopic | seq[ContentTopic],
): Result[Table[NsPubsubTopic, seq[NsContentTopic]], string] =
  var topics: seq[ContentTopic]
  when contentTopics is seq[ContentTopic]:
    topics = contentTopics
  else:
    topics = @[contentTopics]

  var topicMap = initTable[NsPubsubTopic, seq[NsContentTopic]]()
  for contentTopic in topics:
    let parseRes = NsContentTopic.parse(contentTopic)

    let content =
      if parseRes.isErr():
        return err("Cannot parse content topic: " & $parseRes.error)
      else:
        parseRes.get()

    let pubsub =
      if pubsubTopic.isSome():
        let parseRes = NsPubsubTopic.parse(pubsubTopic.get())

        if parseRes.isErr():
          return err("Cannot parse pubsub topic: " & $parseRes.error)
        else:
          parseRes.get()
      else:
        let shardsRes = s.getShard(content)

        if shardsRes.isErr():
          return err("Cannot autoshard content topic: " & $shardsRes.error)
        else:
          shardsRes.get()

    if not topicMap.hasKey(pubsub):
      topicMap[pubsub] = @[]

    try:
      topicMap[pubsub].add(content)
    except CatchableError:
      return err(getCurrentExceptionMsg())

  ok(topicMap)

#type ShardsPriority = seq[tuple[topic: NsPubsubTopic, value: float64]]

#[ proc shardCount*(topic: NsContentTopic): Result[int, string] =
  ## Returns the total shard count from the content topic.
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

  ok((shardCount)) ]#

#[ proc applyWeight(hashValue: uint64, weight: float64): float64 =
  (-weight) / math.ln(float64(hashValue) / float64(high(uint64))) ]#

#[ proc hashOrder*(x, y: (NsPubsubTopic, float64)): int =
    cmp(x[1], y[1]) ]#

#[ proc weightedShardList*(topic: NsContentTopic, shardCount: int, weightList: seq[float64]): Result[ShardsPriority, string] =
  ## Returns the ordered list of shards and their priority values.
  if weightList.len < shardCount:
    return err("Must provide weights for every shards")

  let shardsNWeights = zip(toSeq(0..shardCount), weightList)

  var list = newSeq[(NsPubsubTopic, float64)](shardCount)

  for (shard, weight) in shardsNWeights:
    let pubsub = NsPubsubTopic.staticSharding(ClusterId, uint16(shard))

    let clusterBytes = toBytesBE(uint16(ClusterId))
    let shardBytes = toBytesBE(uint16(shard))
    let bytes = toBytes(topic.application) & toBytes(topic.version) & @clusterBytes & @shardBytes
    let hash = sha256.digest(bytes)
    let hashValue = uint64.fromBytesBE(hash.data)
    let value = applyWeight(hashValue, weight)

    list[shard] = (pubsub, value)

  list.sort(hashOrder)

  ok(list) ]#

#[ proc singleHighestWeigthShard*(topic: NsContentTopic): Result[NsPubsubTopic, string] =
  let count = ? shardCount(topic)

  let weights = repeat(1.0, count)

  let list = ? weightedShardList(topic, count, weights)

  let (pubsub, _) = list[list.len - 1]

  ok(pubsub) ]#
